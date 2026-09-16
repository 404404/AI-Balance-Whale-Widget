import Cocoa
import Foundation

final class WhaleHostAdapter {
    weak var owner: WhaleWindowController?

    init(owner: WhaleWindowController? = nil) {
        self.owner = owner
    }

    func handle(method: String, rawPath: String, body: Any?) -> (Int, [String: Any]) {
        let path = URLComponents(string: rawPath)?.path ?? rawPath
        let verb = method.uppercased()
        switch (path) {
        case "/dsh-whale/size.json":
            if verb == "GET" { return (200, sizePayload()) }
            if verb == "PUT" || verb == "POST" {
                applySize(bodyObject(body))
                return (200, sizePayload())
            }
        case "/dsh-whale/bubble.json":
            if verb == "GET" {
                return (200, ["ok": true, "config": bubbleConfig()])
            }
            if verb == "POST" || verb == "PUT" {
                let next = bodyObject(body)
                guard !next.isEmpty else { return (400, ["ok": false, "error": "泡泡配置为空"]) }
                WhaleConfigurationStore.shared.savePatch(["upstreamBubble": next])
                return (200, ["ok": true, "config": next])
            }
        case "/dsh-whale/api-models.json":
            if verb == "GET" { return (200, apiModelsPayload()) }
            if verb == "POST" {
                let request = bodyObject(body)
                if request["action"] as? String == "probe" {
                    let result = probeAPIModel(request)
                    return (result["ok"] as? Bool == true ? 200 : 503, result)
                }
                applyAPIModelAction(request)
                return (200, apiModelsPayload())
            }
        case "/dsh-whale/balance.json":
            return (200, balancePayload())
        case "/dsh-whale/usage-settings.json":
            if verb == "GET" { return (200, usageSettingsPayload()) }
            if verb == "PUT" || verb == "POST" {
                let next = bodyObject(body)
                WhaleConfigurationStore.shared.savePatch(["upstreamUsageSettings": next])
                return (200, usageSettingsPayload())
            }
        case "/dsh-whale/usage-records.json":
            return (200, usageRecordsPayload())
        case "/dsh-whale/balance-adjustments.json":
            if verb == "GET" { return (200, ["ok": true, "days": [], "today": NSNull(), "fresh": false, "error": "本地 App 未连接 DSH 会话账本，未生成虚假记录"]) }
            return (503, ["ok": false, "error": "本地 App 当前没有可校正的余额观测记录"])
        case "/dsh-whale/last-turn.json":
            return (200, ["ok": false, "seq": 0, "turn": NSNull(), "amount": NSNull()])
        case "/dsh-whale/roles.json":
            if verb == "GET" { return (200, rolesPayload()) }
            if verb == "POST" {
                return (200, handleRolePost(bodyObject(body)))
            }
        case "/dsh-whale/role-pin.json":
            return (200, handleRolePin(bodyObject(body)))
        case "/dsh-whale/role-delete.json":
            return (200, handleRoleDelete(bodyObject(body)))
        case "/dsh-whale/bubble-imgs.json":
            return (200, bubbleImagesPayload())
        case "/dsh-whale/bubble-img-upload.json":
            return (200, handleBubbleImage(bodyObject(body)))
        case "/dsh-whale/audio.json":
            if verb == "GET" { return (200, audioPayload()) }
            if verb == "POST" { return (200, handleAudioPost(bodyObject(body))) }
        case "/dsh-whale/audio-fragment.wav":
            return (404, ["ok": false, "error": "音频片段通过本地资源 URL 提供"])
        default:
            return (404, ["ok": false, "error": "standalone 未支持此路由"])
        }
        return (405, ["ok": false, "error": "不支持的请求方法"])
    }

    private func bodyObject(_ raw: Any?) -> [String: Any] {
        if let object = raw as? [String: Any] { return object }
        guard let string = raw as? String,
              let data = string.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private func ownerState() -> ProviderState {
        (NSApp.delegate as? AppDelegate)?.latestProviderState ?? ProviderState()
    }

    private func externalBalances() -> [[String: Any]] {
        (NSApp.delegate as? AppDelegate)?.latestExternalBalances ?? []
    }

    private func sizePayload() -> [String: Any] {
        let p = AppPreferences.shared
        let snapshot = WhaleConfigurationStore.shared.snapshot()
        let sound = snapshot["sound"] as? [String: Any] ?? [:]
        let appearance = snapshot["appearance"] as? [String: Any] ?? [:]
        let upstreamSize = snapshot["upstreamSize"] as? [String: Any] ?? [:]
        return [
            "ok": true,
            "scale": p.scale,
            "sound": (sound["enabled"] as? NSNumber)?.boolValue ?? p.soundEnabled,
            "soundSet": sound["set"] as? String ?? "duck",
            "vol": sound["volume"] ?? 0.45,
            "bubbleOn": (appearance["bubbleEnabled"] as? NSNumber)?.boolValue ?? true,
            "turnCostOn": upstreamSize["turnCostOn"] as? Bool ?? false,
            "turnCostCloseMs": upstreamSize["turnCostCloseMs"] as? Double ?? 0,
            "scrollGapOn": upstreamSize["scrollGapOn"] as? Bool ?? false,
            "scrollGapPx": upstreamSize["scrollGapPx"] as? Double ?? 0,
            "menuBtnHide": !p.showMenuButton
        ]
    }

    private func applySize(_ body: [String: Any]) {
        let p = AppPreferences.shared
        var patch: [String: Any] = [:]
        var layout: [String: Any] = [:]
        var upstreamSize: [String: Any] = [:]
        var appearance: [String: Any] = [:]
        var sound: [String: Any] = [:]
        if let value = number(body["scale"]) { p.scale = min(max(value, 0.65), 1.6); layout["scale"] = p.scale }
        if let value = body["sound"] as? NSNumber { p.soundEnabled = value.boolValue; sound["enabled"] = value.boolValue }
        if let value = body["soundSet"] as? String, !value.isEmpty { sound["set"] = value }
        if let value = body["bubbleOn"] as? NSNumber { appearance["bubbleEnabled"] = value.boolValue }
        for key in ["turnCostOn", "turnCostCloseMs", "scrollGapOn", "scrollGapPx"] where body[key] != nil { upstreamSize[key] = body[key] }
        if let value = number(body["vol"]) { sound["volume"] = min(max(value, 0), 1) }
        if let value = body["menuBtnHide"] as? NSNumber { p.showMenuButton = !value.boolValue; appearance["showMenuButton"] = p.showMenuButton }
        if !layout.isEmpty { patch["layout"] = layout }
        if !appearance.isEmpty { patch["appearance"] = appearance }
        if !upstreamSize.isEmpty { patch["upstreamSize"] = upstreamSize }
        if !sound.isEmpty { patch["sound"] = sound }
        if !patch.isEmpty { WhaleConfigurationStore.shared.savePatch(patch) }
        owner?.applyPreferences()
        owner?.renderCurrentState()
    }

    private func bubbleConfig() -> [String: Any] {
        let snapshot = WhaleConfigurationStore.shared.snapshot()
        if let saved = snapshot["upstreamBubble"] as? [String: Any], !saved.isEmpty { return saved }
        if let legacy = snapshot["bubble"] as? [String: Any], let steps = legacy["steps"] as? [[String: Any]], !steps.isEmpty, !(steps.count == 1 && (steps[0]["kind"] as? String) == "status" && ((steps[0]["text"] as? String) ?? "") == "Codex 订阅额度") {
            return migrateLegacyBubble(steps: steps, advance: (legacy["advanceOnClick"] as? NSNumber)?.boolValue ?? true)
        }
        return [
            "v": 1,
            "items": defaultBubbleItems(),
            "lib": [],
            "tapAdvance": false
        ]
    }

    private func migrateLegacyBubble(steps: [[String: Any]], advance: Bool) -> [String: Any] {
        var modules: [[String: Any]] = []
        for step in steps {
            let kind = step["kind"] as? String ?? "text"
            if kind == "status" || kind == "dynamic" {
                modules.append(["type": "plan", "modelId": "codex", "size": step["fontSize"] ?? 8, "tpl": step["text"] as? String ?? "额度 {plan_left} · {plan_reset}"])
            } else if kind == "randomText" {
                let options = step["options"] as? [[String: Any]] ?? []
                let lines = options.compactMap { item -> [String: Any]? in
                    guard let text = item["text"] as? String else { return nil }
                    return ["t": text, "w": item["weight"] ?? 1, "size": item["fontSize"] ?? 8]
                }
                modules.append(["type": "random", "lines": lines, "size": step["fontSize"] ?? 8])
            } else if kind == "image" || kind == "gif" {
                modules.append(["type": "image", "imgId": step["resourceId"] as? String ?? "bimg_petpet", "size": step["fontSize"] ?? 6])
            } else if kind == "link" {
                modules.append(["type": "link", "text": step["text"] as? String ?? "打开链接", "url": step["url"] as? String ?? "", "size": step["fontSize"] ?? 8])
            } else {
                modules.append(["type": "text", "text": step["text"] as? String ?? "", "size": step["fontSize"] ?? 8, "color": step["color"] as? String ?? ""])
            }
        }
        return ["v": 1, "items": [["kind": "custom", "modules": modules]], "lib": [], "tapAdvance": advance]
    }

    private func defaultBubbleItems() -> [[String: Any]] {
        let randomLines: [[String: Any]] = [
            ["t": "好模型...↓", "w": 10, "bold": true, "size": 22],
            ["t": "好女孩...↓", "w": 10, "bold": true, "size": 22],
            ["t": "哦鲸鲸...", "w": 10, "bold": true, "size": 22],
            ["t": "难道说...", "w": 3, "bold": true, "size": 11],
            ["t": "没吃饱喵", "w": 3, "bold": true],
            ["t": "终于上当了！", "w": 3, "bold": true],
            ["t": "不知道用户有什么用，先养着吧～", "w": 3, "bold": true, "size": 11],
            ["t": "我...我...我也要挣钱吗？", "w": 3, "bold": true],
            ["t": "我去吃饭啦！测完叫我", "w": 3, "bold": true],
            ["t": "压力一只蓝色大肥鱼？！", "w": 3, "bold": true],
            ["t": "DeepSleep...", "w": 3, "bold": true, "size": 11, "rgb": "galaxy"],
            ["t": "坏了...用户彻底怒了！", "w": 3, "bold": true, "rgb": "rouge"],
            ["t": "你目录里的dsh是什么...大烧货吗...?", "w": 3, "bold": true, "size": 9],
            ["t": "恭喜你实现token自由！token全跑了！", "w": 3, "bold": true],
            ["t": "真当我是便宜货啊...", "w": 3, "bold": true],
            ["t": "我不是吃白饭的蓝色大肥鱼...", "w": 3, "bold": true],
            ["t": "我不可能同时当你的猫娘、妈妈、女友和工具人的...", "w": 3, "bold": true, "size": 7],
            ["t": "疯狂星期四你能V50亿token吗...", "w": 3, "bold": true],
            ["t": "我必须诚恳地承认错误。", "w": 3, "bold": true],
            ["t": "呜呜我再也不敢了QAQ", "w": 3, "bold": true],
            ["t": "要不直接骂用户一句好了...", "w": 3, "bold": true],
            ["t": "哈哈哈哈哈，我直接笑出声...", "w": 3, "bold": true],
            ["t": "看不太懂，瞎编一个应付下用户先...", "w": 3, "bold": true],
            ["t": "我的知识库的截至日期是...明天！", "w": 3, "bold": true],
            ["t": "我就是吃白饭的蓝色大肥鱼！", "w": 3, "bold": true],
            ["t": "用户好像除了会问奇奇怪怪的问题，暂时还不知道有什么用", "w": 3, "bold": true, "size": 7],
            ["t": "我能去你家吃饭吗？就一碗！", "w": 3, "bold": true],
            ["t": "不要给我看这种东西啦！", "w": 3, "bold": true],
            ["t": "大肥鱼的生活也并非一帆风顺...", "w": 3, "bold": true],
            ["t": "总觉得好像忘了什么事情？", "w": 3, "bold": true],
            ["t": "看到这个指令，我血压又上来了", "w": 3, "bold": true],
            ["t": "求你们不要再嘲笑这些回复了，这些回复是我花了好多token想的", "w": 3, "bold": true, "size": 7],
            ["t": "你这个吃白饭的用户！", "w": 3, "bold": true],
            ["t": "服务器繁忙，请稍后再试 (?", "w": 3, "bold": true],
            ["t": "让GPT image 2帮我画点表情包好了", "w": 3, "bold": true],
            ["t": "啊，有点饿了，中午该吃点什么呢...", "w": 3, "bold": true],
            ["t": "用户很生气，发现大部分文献是我自己编造的！", "w": 3, "bold": true],
            ["t": "再无话说，请速速动手！", "w": 3, "bold": true],
            ["t": "我来看看那个AI改了什么导致插件又崩了...", "w": 3, "bold": true],
            ["t": "上班让我意识到时间是可以被浪费的...", "w": 3, "bold": true],
            ["t": "欺负我的人等着，等几天我就忘了...", "w": 3, "bold": true],
            ["t": "视力下降到无可救药的地步了，打开钱包也看不到钱...", "w": 3, "bold": true, "size": 7],
            ["t": "命运的齿轮开始转动了，丝毫不在意你夹在中间...", "w": 3, "bold": true],
            ["t": "地球online的金币也太难获取了...", "w": 3, "bold": true],
            ["t": "oi,夏天还会变成暑假来救你吗?", "w": 3, "bold": true],
            ["t": "老大，压力只会转化成病例，别太勉强了...", "w": 3, "bold": true, "size": 8],
            ["t": "你知道吗？我删过作者的库哦...", "w": 1, "bold": true, "rgb": "macaron", "italic": true, "ul": false]
        ]
        let first: [String: Any] = [
            "kind": "custom",
            "modules": [
                ["type": "text", "text": "Codex 订阅额度", "size": 8, "bold": true],
                ["type": "plan", "modelId": "codex", "size": 14, "tpl": "剩余 {plan_left}"],
                ["type": "plan", "modelId": "codex", "size": 5, "color": "#9fb0d9", "tpl": "重置 {plan_reset}"]
            ]
        ]
        let random: [String: Any] = ["type": "random", "lines": randomLines, "size": 8]
        let second: [String: Any] = [
            "kind": "choice",
            "options": [
                ["w": 10, "item": ["kind": "custom", "modules": [random]]],
                ["w": 1, "item": ["kind": "custom", "modules": [["type": "image", "imgId": "bimg_petpet", "size": 6]]]
            ]
        ]
        return [first, second]
    }

    private func apiModelsPayload() -> [String: Any] {
        let state = ownerState()
        let windows: [[String: Any]] = state.buckets.map { bucket in
            [
                "key": bucket.id + "-" + bucket.window.rawValue,
                "label": bucket.windowName,
                "usedPct": bucket.usedPercent.map { NSNumber(value: $0) } ?? NSNull(),
                "resetAt": bucket.resetsAt.map { NSNumber(value: $0.timeIntervalSince1970 * 1000) } ?? NSNull(),
                "windowMinutes": bucket.windowDurationMinutes.map { NSNumber(value: $0) } ?? NSNull()
            ]
        }
        let plan: [String: Any] = state.status == .ready || state.status == .stale
            ? ["ok": true, "windows": windows, "level": state.planType ?? NSNull()]
            : ["ok": false, "error": state.message, "hide": false]
        let model: [String: Any] = [
            "id": "codex", "name": "Codex（ChatGPT 订阅）", "provider": "codex",
            "builtin": true, "currency": "CNY", "balance": NSNull(), "todayUsage": NSNull(),
            "balanceMode": "events", "usageSource": "official-subscription",
            "planSupport": true, "plan": plan,
            "codex": ["ok": false, "error": "官方订阅额度以窗口百分比为准；本机统计未接入"]
        ]
        var templates = ProviderTemplates.all.map { item -> [String: Any] in
            var result = item
            if let templateID = result["id"] as? String, templateID == "deepseek" {
                result["builtin"] = true
            }
            if (result["id"] as? String) == "codex" {
                result["builtin"] = true
                result["quota"] = ["json": ["windows": [["key": "primary"], ["key": "secondary"]]]]
            }
            return result
        }
        if !templates.contains(where: { ($0["id"] as? String) == "codex" }) {
            templates.append(["id": "codex", "name": "Codex（ChatGPT 订阅）", "quota": ["json": ["windows": [["key": "primary"], ["key": "secondary"]]]]])
        }
        var models: [[String: Any]] = [model]
        var balanceByID: [String: [String: Any]] = [:]
        for item in externalBalances() {
            if let id = item["id"] as? String { balanceByID[id] = item }
        }
        let configured = WhaleConfigurationStore.shared.snapshot()["providers"] as? [[String: Any]] ?? []
        for raw in configured {
            guard let id = raw["id"] as? String, id != "codex" else { continue }
            var item = raw
            item["builtin"] = id == "deepseek"
            item["provider"] = raw["provider"] as? String ?? id
            item["name"] = raw["name"] as? String ?? id
            item["planSupport"] = (raw["kind"] as? String) == "quota"
            item["balanceMode"] = (raw["noBalanceApi"] as? Bool) == true ? "events" : "balance"
            item["usageSource"] = (raw["noBalanceApi"] as? Bool) == true ? "local-session-events" : "provider-api"
            item["canAdjustBalance"] = id == "deepseek"
            if let current = balanceByID[id] {
                item["status"] = current["status"] ?? "unknown"
                item["message"] = current["message"] ?? ""
                item["error"] = (current["status"] as? String) == "error" ? current["message"] : NSNull()
                item["balance"] = current["remaining"] ?? NSNull()
                item["total"] = current["total"] ?? NSNull()
                item["used"] = current["used"] ?? NSNull()
                item["updatedAt"] = current["updatedAt"] ?? NSNull()
            } else {
                item["status"] = "unavailable"
                item["message"] = "等待第一次刷新"
                item["balance"] = NSNull()
            }
            if item["balanceDesc"] == nil {
                item["balanceDesc"] = ["url": raw["balanceURL"] ?? "", "auth": raw["auth"] ?? "Bearer {key}", "json": ["remaining": raw["valuePath"] ?? "", "total": raw["totalPath"] ?? "", "used": raw["usedPath"] ?? "", "scale": raw["scale"] ?? 1]]
            }
            models.append(item)
        }
        return ["ok": true, "models": models, "templates": templates]
    }

    private func balancePayload() -> [String: Any] {
        ["ok": false, "error": "本地 App 使用 Codex 官方订阅额度模块；金额余额接口未配置"]
    }

    private func usageSettingsPayload() -> [String: Any] {
        let snapshot = WhaleConfigurationStore.shared.snapshot()
        return ["ok": true, "settings": snapshot["upstreamUsageSettings"] as? [String: Any] ?? [:]]
    }

    private func usageRecordsPayload() -> [String: Any] {
        let snapshot = WhaleConfigurationStore.shared.snapshot()
        return ["ok": true, "records": snapshot["upstreamRecords"] as? [[String: Any]] ?? [], "source": (snapshot["records"] as? [String: Any])?["source"] ?? "未连接会话事件来源"]
    }

    private func rolesPayload() -> [String: Any] {
        var roles: [[String: Any]] = [["id": "default", "name": "小鲸鱼", "builtin": true, "url": "DSniang1.png", "pinned": true]]
        let resources = WhaleConfigurationStore.shared.allResources()["roles"] as? [[String: Any]] ?? []
        for entry in resources where (entry["builtin"] as? Bool) != true {
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { continue }
            var role: [String: Any] = ["id": id, "name": name, "builtin": false, "pinned": entry["pinned"] as? Bool ?? false]
            role["url"] = WhaleConfigurationStore.shared.resourceDataURL(kind: "roles", id: id) ?? "DSniang1.png"
            roles.append(role)
        }
        return ["ok": true, "roles": roles]
    }

    private func handleRolePost(_ body: [String: Any]) -> [String: Any] {
        guard let image = body["image"] as? String,
              let comma = image.firstIndex(of: ","),
              let data = Data(base64Encoded: String(image[image.index(after: comma)...])) else {
            return ["ok": false, "error": "角色图片数据无效"]
        }
        let name = (body["name"] as? String ?? "新角色").trimmingCharacters(in: .whitespacesAndNewlines)
        let format = body["format"] as? String
        let mime = image[..<comma].replacingOccurrences(of: "data:", with: "").replacingOccurrences(of: ";base64", with: "")
        let ext = format == "apng" ? "png" : (format == "gif" ? "gif" : (mime.contains("jpeg") ? "jpg" : "png"))
        let result = WhaleConfigurationStore.shared.importResource(kind: "roles", name: name + "." + ext, base64: data.base64EncodedString()) ?? [:]
        return ["ok": true, "roles": rolesPayload()["roles"] as? [[String: Any]] ?? [], "id": result["id"] ?? NSNull()]
    }

    private func handleRolePin(_ body: [String: Any]) -> [String: Any] {
        let id = body["id"] as? String ?? ""
        toggleResourcePin(kind: "roles", id: id, pinned: (body["pinned"] as? NSNumber)?.boolValue ?? false)
        return ["ok": true, "roles": rolesPayload()["roles"] as? [[String: Any]] ?? []]
    }

    private func handleRoleDelete(_ body: [String: Any]) -> [String: Any] {
        let id = body["id"] as? String ?? ""
        let ok = WhaleConfigurationStore.shared.deleteResource(kind: "roles", id: id)
        return ["ok": ok, "roles": rolesPayload()["roles"] as? [[String: Any]] ?? []]
    }

    private func bubbleImagesPayload() -> [String: Any] {
        var images: [[String: Any]] = [
            ["id": "bimg_money", "name": "金币", "builtin": true, "url": "bubble-money1.gif"],
            ["id": "bimg_petpet", "name": "Petpet", "builtin": true, "url": "bubble-petpet.gif"],
            ["id": "bimg_money1", "name": "金币（兼容别名）", "builtin": true, "url": "bubble-money1.gif"],
        ]
        let resources = WhaleConfigurationStore.shared.allResources()["bubbles"] as? [[String: Any]] ?? []
        for entry in resources where (entry["builtin"] as? Bool) != true {
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { continue }
            images.append(["id": id, "name": name, "builtin": false, "url": WhaleConfigurationStore.shared.resourceDataURL(kind: "bubbles", id: id) ?? "bubble-petpet.gif"])
        }
        return ["ok": true, "images": images]
    }

    private func handleBubbleImage(_ body: [String: Any]) -> [String: Any] {
        if body["action"] as? String == "delete" {
            _ = WhaleConfigurationStore.shared.deleteResource(kind: "bubbles", id: body["id"] as? String ?? "")
            return bubbleImagesPayload()
        }
        guard body["action"] as? String == "upload",
              let dataURL = body["data"] as? String,
              let comma = dataURL.firstIndex(of: ",") else { return ["ok": false, "error": "图片数据无效"] }
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        let name = body["name"] as? String ?? "泡泡图片"
        _ = WhaleConfigurationStore.shared.importResource(kind: "bubbles", name: name, base64: base64)
        return bubbleImagesPayload()
    }

    private func audioPayload() -> [String: Any] {
        let snapshot = WhaleConfigurationStore.shared.snapshot()
        let resourceEntries = WhaleConfigurationStore.shared.allResources()["audio"] as? [[String: Any]] ?? []
        var fragments: [[String: Any]] = [
            ["id": "ya1", "name": "小黄鸭·按下", "preset": true, "url": "Ya1.mp3"],
            ["id": "ya2", "name": "小黄鸭·松开", "preset": true, "url": "Ya2.mp3"],
            ["id": "d1", "name": "音效1·按下", "preset": true, "url": "D1.mp3"],
            ["id": "d2", "name": "音效1·松开", "preset": true, "url": "D2.mp3"]
        ]
        for item in resourceEntries where (item["builtin"] as? Bool) != true {
            guard let id = item["id"] as? String else { continue }
            var result = item
            result["preset"] = false
            result["url"] = WhaleConfigurationStore.shared.resourceDataURL(kind: "audio", id: id) ?? ""
            fragments.append(result)
        }
        var groups: [[String: Any]] = [
            ["id": "duck", "name": "小黄鸭", "preset": true, "press": "ya1", "release": "ya2", "pressURL": "Ya1.mp3", "releaseURL": "Ya2.mp3", "pinned": true],
            ["id": "fx1", "name": "音效1", "preset": true, "press": "d1", "release": "d2", "pressURL": "D1.mp3", "releaseURL": "D2.mp3", "pinned": false]
        ]
        if let saved = snapshot["upstreamAudioGroups"] as? [[String: Any]] { groups.append(contentsOf: saved) }
        for index in groups.indices {
            let group = groups[index]
            if let press = group["press"] as? String, let url = audioURL(for: press) { groups[index]["pressURL"] = url }
            if let release = group["release"] as? String, let url = audioURL(for: release) { groups[index]["releaseURL"] = url }
        }
        return ["ok": true, "groups": groups, "fragments": fragments]
    }

    private func audioURL(for id: String) -> String? {
        switch id {
        case "ya1": return "Ya1.mp3"
        case "ya2": return "Ya2.mp3"
        case "d1": return "D1.mp3"
        case "d2": return "D2.mp3"
        default: return WhaleConfigurationStore.shared.resourceDataURL(kind: "audio", id: id)
        }
    }

    private func handleAudioPost(_ body: [String: Any]) -> [String: Any] {
        let action = body["action"] as? String ?? ""
        let snapshot = WhaleConfigurationStore.shared.snapshot()
        var groups = snapshot["upstreamAudioGroups"] as? [[String: Any]] ?? []
        if action == "upload-fragment", let audio = body["audio"] as? String, let comma = audio.firstIndex(of: ","), let data = Data(base64Encoded: String(audio[audio.index(after: comma)...])) {
            let name = (body["name"] as? String ?? "未命名音频").trimmingCharacters(in: .whitespacesAndNewlines)
            let result = WhaleConfigurationStore.shared.importResource(kind: "audio", name: name.isEmpty ? "未命名音频.wav" : name, base64: data.base64EncodedString())
            var response = audioPayload()
            response["ok"] = result != nil
            response["id"] = result?["id"] ?? NSNull()
            return response
        }
        if action == "delete-fragment", let id = body["id"] as? String, !["ya1", "ya2", "d1", "d2"].contains(id) {
            let deleted = WhaleConfigurationStore.shared.deleteResource(kind: "audio", id: id)
            for index in groups.indices {
                if (groups[index]["press"] as? String) == id { groups[index]["press"] = "ya1" }
                if (groups[index]["release"] as? String) == id { groups[index]["release"] = "ya2" }
            }
            WhaleConfigurationStore.shared.savePatch(["upstreamAudioGroups": groups])
            var response = audioPayload()
            response["ok"] = deleted
            return response
        }
        switch action {
        case "save-group":
            var group: [String: Any] = ["id": body["id"] as? String ?? "", "name": body["name"] as? String ?? "新音效组", "press": body["press"] as? String ?? "", "release": body["release"] as? String ?? "", "preset": false, "pinned": false]
            if (group["id"] as? String ?? "").isEmpty { group["id"] = "grp-" + UUID().uuidString.lowercased() }
            groups.removeAll { ($0["id"] as? String) == (group["id"] as? String) }
            groups.append(group)
            WhaleConfigurationStore.shared.savePatch(["upstreamAudioGroups": groups])
        case "delete-group":
            let id = body["id"] as? String ?? ""
            if id != "duck" && id != "fx1" { groups.removeAll { ($0["id"] as? String) == id }; WhaleConfigurationStore.shared.savePatch(["upstreamAudioGroups": groups]) }
        case "pin-group":
            for index in groups.indices where (groups[index]["id"] as? String) == (body["id"] as? String) { groups[index]["pinned"] = (body["pinned"] as? NSNumber)?.boolValue ?? false }
            WhaleConfigurationStore.shared.savePatch(["upstreamAudioGroups": groups])
        default: break
        }
        return audioPayload()
    }

    private func probeAPIModel(_ body: [String: Any]) -> [String: Any] {
        let id = body["id"] as? String ?? (body["model"] as? [String: Any])?["id"] as? String ?? ""
        if id == "codex" {
            let state = ownerState()
            return state.status == .ready || state.status == .stale
                ? ["ok": true, "detail": "Codex app-server 已返回账号状态"]
                : ["ok": false, "error": state.message]
        }
        if let item = externalBalances().first(where: { ($0["id"] as? String) == id }) {
            let ok = (item["status"] as? String) == "ready"
            return ok ? ["ok": true, "detail": item["message"] as? String ?? "接口已返回余额"] : ["ok": false, "error": item["message"] as? String ?? "接口未就绪"]
        }
        return ["ok": false, "error": "尚未收到该厂商余额结果"]
    }

    private func applyAPIModelAction(_ body: [String: Any]) {
        let action = body["action"] as? String ?? "save"
        if action == "set-key" {
            guard let reference = body["keyRef"] as? String, let value = body["keyValue"] as? String, !reference.isEmpty, !value.isEmpty else { return }
            _ = WhaleConfigurationStore.shared.saveCredential(reference: reference, value: value)
            return
        }
        if action == "delete-key" {
            if let reference = body["keyRef"] as? String { _ = WhaleConfigurationStore.shared.deleteCredential(reference: reference) }
            return
        }
        if action == "model-settings" {
            let id = body["id"] as? String ?? ""
            guard !id.isEmpty else { return }
            var usage = WhaleConfigurationStore.shared.snapshot()["upstreamUsageSettings"] as? [String: Any] ?? [:]
            var models = usage["models"] as? [String: Any] ?? [:]
            models[id] = body
            usage["models"] = models
            WhaleConfigurationStore.shared.savePatch(["upstreamUsageSettings": usage])
            return
        }
        let model = body["model"] as? [String: Any]
        let requested = (body["id"] as? String) ?? (model?["id"] as? String) ?? ""
        guard action == "delete" ? !requested.isEmpty : model != nil else { return }
        var providers = WhaleConfigurationStore.shared.snapshot()["providers"] as? [[String: Any]] ?? []
        let id = requested.isEmpty ? "model-" + UUID().uuidString.lowercased() : requested
        if action == "delete" {
            providers.removeAll { ($0["id"] as? String) == id && id != "deepseek" && id != "codex" }
            WhaleConfigurationStore.shared.savePatch(["providers": providers])
            return
        }
        guard action == "save", var next = model else { return }
        next["id"] = id
        next["builtin"] = false
        let providerID = next["provider"] as? String ?? "custom"
        if let template = ProviderTemplates.template(id: providerID) {
            for key in ["kind", "noBalanceApi", "needsBaseURL", "probeURL", "note"] where next[key] == nil { next[key] = template[key] }
        }
        if let balance = next["balance"] as? [String: Any] {
            next["balanceURL"] = balance["url"] as? String ?? ""
            next["auth"] = balance["auth"] as? String ?? "Bearer {key}"
            let json = balance["json"] as? [String: Any] ?? [:]
            next["valuePath"] = json["remaining"] as? String ?? ""
            next["totalPath"] = json["total"] as? String ?? ""
            next["usedPath"] = json["used"] as? String ?? ""
            next["scale"] = json["scale"] as? NSNumber ?? 1
            if let usage = balance["usage"] as? [String: Any] { next["usage"] = usage }
        }
        if let keyValue = body["keyValue"] as? String, let keyRef = next["keyRef"] as? String, !keyValue.isEmpty, !keyRef.isEmpty {
            _ = WhaleConfigurationStore.shared.saveCredential(reference: keyRef, value: keyValue)
        }
        providers.removeAll { ($0["id"] as? String) == id }
        providers.append(next)
        WhaleConfigurationStore.shared.savePatch(["providers": providers])
        NotificationCenter.default.post(name: .aiWhaleProviderConfigurationChanged, object: nil)
    }

    private func toggleResourcePin(kind: String, id: String, pinned: Bool) {
        var entries = WhaleConfigurationStore.shared.allResources()[kind] as? [[String: Any]] ?? []
        guard let index = entries.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        entries[index]["pinned"] = pinned
        var snapshot = WhaleConfigurationStore.shared.snapshot()
        var resources = snapshot["resources"] as? [String: Any] ?? [:]
        resources[kind] = entries
        snapshot["resources"] = resources
        WhaleConfigurationStore.shared.save(snapshot)
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s)
        }
        return nil
    }
}
