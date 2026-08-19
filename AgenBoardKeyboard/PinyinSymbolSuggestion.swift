import Foundation

struct PinyinDisplayCandidate: Equatable {
    let text: String
    let source: Source
    let anchorText: String?

    enum Source: Equatable {
        case engine
        case symbol
        case rawComposition
    }

    var isSymbol: Bool {
        source == .symbol
    }
}

struct PinyinCandidatePage {
    let candidates: [PinyinDisplayCandidate]
    let hasMore: Bool
    let nextOffset: Int
}

/// Inserts emoji and other symbols immediately after the Chinese word they
/// belong to, without mixing those symbols into the Rime user dictionary.
enum PinyinSymbolSuggestion {
    static let compactLimit = 1
    static let expandedLimit = 4

    static func decorate(
        _ texts: [String],
        limit: Int,
        preferences: PinyinSymbolSuggestionPreferences = SharedCommandStore
            .pinyinSymbolSuggestionPreferences(),
        excluding usedSymbols: Set<String> = []
    ) -> [PinyinDisplayCandidate] {
        guard preferences.isEnabled, limit > 0 else {
            return texts.map { item in
                PinyinDisplayCandidate(text: item, source: .engine, anchorText: nil)
            }
        }

        var decorated: [PinyinDisplayCandidate] = []
        var consumedSymbols = usedSymbols
        decorated.reserveCapacity(texts.count + min(texts.count, 8))

        for text in texts {
            decorated.append(
                PinyinDisplayCandidate(text: text, source: .engine, anchorText: nil)
            )

            let symbols = rankedSymbols(
                for: text,
                preferences: preferences,
                excluding: consumedSymbols
            )
            guard !symbols.isEmpty else {
                continue
            }

            for symbol in symbols.prefix(limit) {
                consumedSymbols.insert(symbol)
                decorated.append(
                    PinyinDisplayCandidate(
                        text: symbol,
                        source: .symbol,
                        anchorText: text
                    )
                )
            }
        }

        return decorated
    }

    static func recordSelection(_ candidate: PinyinDisplayCandidate) {
        guard candidate.isSymbol, let anchorText = candidate.anchorText else {
            return
        }
        SharedCommandStore.recordPinyinSymbolSelection(
            symbol: candidate.text,
            for: anchorText
        )
    }

    static func rankedSymbols(
        for text: String,
        preferences: PinyinSymbolSuggestionPreferences = SharedCommandStore
            .pinyinSymbolSuggestionPreferences(),
        excluding usedSymbols: Set<String> = []
    ) -> [String] {
        guard preferences.isEnabled else {
            return []
        }

        let key = SharedCommandStore.normalizedPinyinSymbolAnchor(text)
        guard !key.isEmpty else {
            return []
        }

        let catalog = builtinCatalog[key] ?? []
        let learned = preferences.learnedRanks[key] ?? [:]
        var seen = Set<String>()
        var ranked: [(symbol: String, score: Int, catalogIndex: Int)] = []

        func append(symbol: String, catalogIndex: Int) {
            let normalizedSymbol = symbol.precomposedStringWithCanonicalMapping
            guard !normalizedSymbol.isEmpty,
                  !usedSymbols.contains(normalizedSymbol),
                  seen.insert(normalizedSymbol).inserted else {
                return
            }
            let learnedCount = learned[normalizedSymbol] ?? 0
            ranked.append(
                (
                    symbol: normalizedSymbol,
                    score: learnedCount * 1_000 - catalogIndex,
                    catalogIndex: catalogIndex
                )
            )
        }

        for (index, symbol) in catalog.enumerated() {
            append(symbol: symbol, catalogIndex: index)
        }
        for symbol in learned.keys where !seen.contains(symbol) {
            append(symbol: symbol, catalogIndex: catalog.count + 50)
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.catalogIndex < rhs.catalogIndex
                }
                return lhs.score > rhs.score
            }
            .map { item in
                item.symbol
            }
    }

    private static let builtinCatalog: [String: [String]] = [
        "花": ["🌹", "🌻", "💐", "🌷", "🌸", "🌺", "🌼", "🥀"],
        "玫瑰": ["🌹"],
        "向日葵": ["🌻"],
        "花束": ["💐"],
        "郁金香": ["🌷"],
        "樱花": ["🌸"],
        "信封": ["✉️", "💌", "📧"],
        "信": ["✉️", "💌"],
        "邮件": ["📧", "✉️"],
        "信奉": ["🙏"],
        "祈祷": ["🙏"],
        "拜托": ["🙏"],
        "星星": ["✨", "🌟", "⭐", "💫"],
        "星": ["⭐", "🌟", "✨"],
        "行星": ["🪐"],
        "猩猩": ["🦍"],
        "哈哈": ["😂", "😄", "😆", "😁", "😃"],
        "哈哈哈": ["😂", "🤣"],
        "笑": ["😄", "😊", "😆"],
        "火": ["🔥"],
        "火焰": ["🔥"],
        "爱": ["❤️", "💕"],
        "爱心": ["❤️", "💖", "💕"],
        "心": ["❤️", "💛", "💙"],
        "喜欢": ["❤️"],
        "月亮": ["🌙", "🌕"],
        "太阳": ["☀️"],
        "下雨": ["🌧️"],
        "雨": ["🌧️", "☔"],
        "雪": ["❄️"],
        "猫": ["🐱", "🐈"],
        "狗": ["🐶", "🐕"],
        "鱼": ["🐟"],
        "鸟": ["🐦"],
        "牛": ["🐮"],
        "马": ["🐴"],
        "猪": ["🐷"],
        "羊": ["🐑"],
        "鸡": ["🐔"],
        "鸭": ["🦆"],
        "熊": ["🐻"],
        "熊猫": ["🐼"],
        "老虎": ["🐯"],
        "狮子": ["🦁"],
        "兔子": ["🐰"],
        "龙": ["🐲", "🐉"],
        "咖啡": ["☕️"],
        "茶": ["🍵"],
        "啤酒": ["🍺"],
        "酒": ["🍷", "🍺"],
        "蛋糕": ["🎂"],
        "苹果": ["🍎"],
        "香蕉": ["🍌"],
        "西瓜": ["🍉"],
        "葡萄": ["🍇"],
        "橙子": ["🍊"],
        "柠檬": ["🍋"],
        "草莓": ["🍓"],
        "桃子": ["🍑"],
        "米饭": ["🍚"],
        "面条": ["🍜"],
        "面包": ["🍞"],
        "汽车": ["🚗"],
        "火车": ["🚄"],
        "飞机": ["✈️"],
        "船": ["🚢"],
        "自行车": ["🚲"],
        "房子": ["🏠"],
        "家": ["🏠"],
        "学校": ["🏫"],
        "医院": ["🏥"],
        "银行": ["🏦"],
        "钱": ["💰"],
        "礼物": ["🎁"],
        "生日": ["🎂", "🎉"],
        "庆祝": ["🎉"],
        "派对": ["🥳", "🎉"],
        "音乐": ["🎵", "🎶"],
        "歌": ["🎤", "🎵"],
        "电影": ["🎬"],
        "相机": ["📷"],
        "照片": ["📸"],
        "电话": ["📞"],
        "手机": ["📱"],
        "电脑": ["💻"],
        "键盘": ["⌨️"],
        "书": ["📖", "📚"],
        "灯": ["💡"],
        "主意": ["💡"],
        "时间": ["⏰"],
        "闹钟": ["⏰"],
        "钥匙": ["🔑"],
        "锁": ["🔒"],
        "对": ["✅"],
        "正确": ["✅"],
        "错": ["❌"],
        "警告": ["⚠️"],
        "赞": ["👍"],
        "棒": ["👍"],
        "厉害": ["👍", "🔥"],
        "加油": ["💪", "🔥"],
        "握手": ["🤝"],
        "再见": ["👋"],
        "你好": ["👋"],
        "哭": ["😢", "😭"],
        "难过": ["😢"],
        "生气": ["😡"],
        "惊讶": ["😲"],
        "害怕": ["😱"],
        "困": ["😴"],
        "睡": ["😴"],
        "晚安": ["😴", "🌙"],
        "思考": ["🤔"],
        "酷": ["😎"],
        "恭喜": ["🎉", "🎊"],
        "胜利": ["✌️"],
        "彩虹": ["🌈"],
        "云": ["☁️"],
        "闪电": ["⚡️"],
        "雷": ["⚡️"],
        "风": ["💨"],
        "树": ["🌳"],
        "草": ["🌿"],
        "叶子": ["🍃"],
        "山": ["⛰️"],
        "海": ["🌊"],
        "水": ["💧"],
        "地球": ["🌍"],
        "世界": ["🌍"],
        "中国": ["🇨🇳"],
        "美国": ["🇺🇸"],
        "日本": ["🇯🇵"],
        "足球": ["⚽️"],
        "篮球": ["🏀"],
        "乒乓球": ["🏓"],
        "网球": ["🎾"],
        "皇冠": ["👑"],
        "钻石": ["💎"],
        "戒指": ["💍"],
        "眼镜": ["👓"],
        "帽子": ["🎩"],
        "鞋": ["👟"],
        "包": ["👜"],
        "工作": ["💼"],
        "会议": ["📅"],
        "日历": ["📅"],
        "亲亲": ["😘"],
        "吻": ["😘"],
        "拥抱": ["🤗"],
        "鬼": ["👻"],
        "便便": ["💩"],
        "药": ["💊"],
        "口罩": ["😷"],
        "跑步": ["🏃"],
        "走路": ["🚶"],
        "跳舞": ["💃"],
        "游泳": ["🏊"],
        "游戏": ["🎮"],
        "红包": ["🧧"],
        "烟花": ["🎆"],
        "灯笼": ["🏮"],
        "一百分": ["💯"],
        "满分": ["💯"]
    ]
}
