import Foundation

enum ProviderTemplates {
    private static func make(
        _ id: String,
        _ name: String,
        _ currency: String,
        _ keyRef: String,
        balanceURL: String = "",
        auth: String = "Bearer {key}",
        valuePath: String = "",
        totalPath: String = "",
        usedPath: String = "",
        scale: Double = 1,
        kind: String = "balance",
        noBalanceAPI: Bool = false,
        needsBaseURL: Bool = false,
        probeURL: String = "",
        note: String = ""
    ) -> [String: Any] {
        [
            "id": id, "name": name, "currency": currency, "keyRef": keyRef,
            "balanceURL": balanceURL, "auth": auth, "valuePath": valuePath,
            "totalPath": totalPath, "usedPath": usedPath, "scale": scale,
            "kind": kind, "noBalanceApi": noBalanceAPI, "needsBaseURL": needsBaseURL,
            "probeURL": probeURL, "note": note,
        ]
    }

    // These are the upstream template IDs/names. Defaults intentionally keep
    // credentials as references only; the values are resolved by native code.
    static let all: [[String: Any]] = [
        make("deepseek", "DeepSeek", "CNY", "DEEPSEEK_API_KEY", balanceURL: "https://api.deepseek.com/user/balance", valuePath: "balance_infos[0].total_balance"),
        make("openrouter", "OpenRouter", "USD", "OPENROUTER_API_KEY", balanceURL: "https://openrouter.ai/api/v1/credits", totalPath: "data.total_credits", usedPath: "data.total_usage"),
        make("siliconflow_cn", "硅基流动（CN）", "CNY", "SILICONFLOW_API_KEY", noBalanceAPI: true, probeURL: "https://api.siliconflow.cn/v1/models", note: "官方余额接口已下线；余额不可用，探活仅验证 key。"),
        make("siliconflow_en", "硅基流动（EN）", "USD", "SILICONFLOW_API_KEY", noBalanceAPI: true, probeURL: "https://api.siliconflow.com/v1/models", note: "官方余额接口已下线；余额不可用，探活仅验证 key。"),
        make("moonshot", "Kimi / Moonshot（CN）", "CNY", "MOONSHOT_API_KEY", balanceURL: "https://api.moonshot.cn/v1/users/me/balance", valuePath: "data.available_balance", probeURL: "https://api.moonshot.cn/v1/models"),
        make("moonshot_intl", "Kimi / Moonshot（国际）", "USD", "MOONSHOT_INTL_API_KEY", balanceURL: "https://api.moonshot.ai/v1/users/me/balance", valuePath: "data.available_balance", probeURL: "https://api.moonshot.ai/v1/models"),
        make("stepfun", "阶跃星辰 StepFun", "CNY", "STEPFUN_API_KEY", balanceURL: "https://api.stepfun.com/v1/accounts", valuePath: "balance"),
        make("novita", "Novita AI", "USD", "NOVITA_API_KEY", balanceURL: "https://api.novita.ai/v3/user/balance", valuePath: "availableBalance", scale: 0.0001),
        make("volcengine_ark", "火山方舟 Ark", "CNY", "ARK_API_KEY", noBalanceAPI: true, probeURL: "https://ark.cn-beijing.volces.com/api/v3/models", note: "余额需要云厂商签名 OpenAPI；此模板只提供探活。"),
        make("zhipu_glm_coding", "智谱 GLM Coding Plan（订阅）", "CNY", "ZHIPU_API_KEY", kind: "quota", probeURL: "https://open.bigmodel.cn/api/monitor/usage/quota/limit"),
        make("kimi_coding", "Kimi Coding（订阅）", "CNY", "KIMI_CODING_KEY", kind: "quota", probeURL: "https://api.kimi.com/coding/v1/usages"),
        make("minimax_coding", "MiniMax Coding（订阅）", "CNY", "MINIMAX_API_KEY", kind: "quota", probeURL: "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"),
        make("openai_compat", "OpenAI 兼容中转站", "USD", "CUSTOM_API_KEY", balanceURL: "{base}/v1/dashboard/billing/subscription", totalPath: "hard_limit_usd", needsBaseURL: true),
        make("custom", "自定义 HTTP", "CNY", "CUSTOM_API_KEY"),
        make("codex", "Codex（ChatGPT 订阅）", "CNY", "", kind: "codex", note: "额度由本机 codex app-server 提供，不使用 API key。"),
        make("openai", "OpenAI", "USD", "OPENAI_API_KEY", noBalanceAPI: true, probeURL: "https://api.openai.com/v1/models", note: "没有公开 API key 余额接口；余额不可用。"),
        make("anthropic", "Anthropic Claude", "USD", "ANTHROPIC_API_KEY", noBalanceAPI: true, note: "没有通用余额接口；余额不可用。"),
        make("gemini", "Google Gemini", "USD", "GEMINI_API_KEY", noBalanceAPI: true, probeURL: "https://generativelanguage.googleapis.com/v1beta/models?key={key}", note: "配额在控制台；余额不可用。"),
        make("xai", "xAI Grok", "USD", "XAI_API_KEY", noBalanceAPI: true, probeURL: "https://api.x.ai/v1/models"),
        make("groq", "Groq", "USD", "GROQ_API_KEY", noBalanceAPI: true, probeURL: "https://api.groq.com/openai/v1/models"),
        make("mistral", "Mistral AI", "USD", "MISTRAL_API_KEY", noBalanceAPI: true, probeURL: "https://api.mistral.ai/v1/models"),
        make("together", "Together AI", "USD", "TOGETHER_API_KEY", noBalanceAPI: true, probeURL: "https://api.together.xyz/v1/models"),
        make("fireworks", "Fireworks AI", "USD", "FIREWORKS_API_KEY", noBalanceAPI: true, probeURL: "https://api.fireworks.ai/inference/v1/models"),
        make("deepinfra", "DeepInfra", "USD", "DEEPINFRA_API_KEY", noBalanceAPI: true, probeURL: "https://api.deepinfra.com/v1/openai/models"),
        make("cerebras", "Cerebras", "USD", "CEREBRAS_API_KEY", noBalanceAPI: true, probeURL: "https://api.cerebras.ai/v1/models"),
        make("dashscope", "阿里云百炼（通义千问）", "CNY", "DASHSCOPE_API_KEY", noBalanceAPI: true, probeURL: "https://dashscope.aliyuncs.com/compatible-mode/v1/models"),
        make("qianfan", "百度千帆（文心）", "CNY", "QIANFAN_API_KEY", noBalanceAPI: true, probeURL: "https://qianfan.baidubce.com/v2/models"),
        make("hunyuan", "腾讯混元", "CNY", "HUNYUAN_API_KEY", noBalanceAPI: true, probeURL: "https://api.hunyuan.cloud.tencent.com/v1/models"),
        make("spark", "讯飞星火", "CNY", "SPARK_API_KEY", noBalanceAPI: true, probeURL: "https://spark-api-open.xf-yun.com/v1/models"),
        make("modelscope", "魔搭 ModelScope", "CNY", "MODELSCOPE_API_KEY", noBalanceAPI: true, probeURL: "https://api-inference.modelscope.cn/v1/models"),
        make("ollama", "本地模型（Ollama / LM Studio）", "CNY", "", noBalanceAPI: true, needsBaseURL: true, probeURL: "{base}/v1/models", note: "本地模型没有余额概念；按会话事件记录 token。"),
        make("zhipu_glm_coding_intl", "智谱 GLM Coding Plan（国际 z.ai）", "USD", "ZHIPU_INTL_API_KEY", kind: "quota", probeURL: "https://api.z.ai/api/monitor/usage/quota/limit"),
        make("minimax_coding_intl", "MiniMax Coding（国际）", "USD", "MINIMAX_INTL_API_KEY", kind: "quota", probeURL: "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"),
    ]

    static func template(id: String) -> [String: Any]? {
        all.first { ($0["id"] as? String) == id }
    }
}
