import Foundation

struct PinyinCandidatePage {
    let candidates: [String]
    let hasMore: Bool
    let nextOffset: Int
}

enum PinyinCandidateSelection: Equatable {
    case committed(String)
    case composing(markedText: String)
}

struct PinyinInputEngine {
    static func prepare() {
        if RimePinyinEngine.shared.prepare() {
            return
        }

        // Rime unavailable is not fatal. Warm the original compact engine so
        // the keyboard can still type instead of losing Chinese input entirely.
        _ = characterIndex
        _ = phraseIndex
        _ = knownSyllables
    }

    static func candidates(for composition: String, limit: Int = 12) -> [String] {
        firstCandidatePage(for: composition, limit: limit).candidates
    }

    static func firstCandidatePage(
        for composition: String,
        limit: Int = 48
    ) -> PinyinCandidatePage {
        // Warmup normally finishes before the first key. If a host opens the
        // extension and immediately types, wait for the same serialized setup
        // here instead of building the much slower legacy CJK index on the UI
        // thread while Rime is still starting in the background.
        if !composition.isEmpty {
            _ = RimePinyinEngine.shared.prepare()
        }
        if let page = RimePinyinEngine.shared.firstCandidatePage(
            for: composition,
            limit: limit
        ) {
            return page
        }

        return fallbackCandidatePage(
            for: composition,
            offset: 0,
            limit: limit
        )
    }

    static func nextCandidatePage(
        for composition: String,
        offset: Int,
        limit: Int = 48
    ) -> PinyinCandidatePage {
        if let page = RimePinyinEngine.shared.nextCandidatePage(
            for: composition,
            offset: offset,
            limit: limit
        ) {
            return page
        }

        return fallbackCandidatePage(
            for: composition,
            offset: offset,
            limit: limit
        )
    }

    static func selection(
        for candidate: String,
        composition: String
    ) -> PinyinCandidateSelection? {
        RimePinyinEngine.shared.selectCandidate(
            candidate,
            for: composition,
            commitRemainingComposition: false
        )
    }

    static func selectedText(
        for candidate: String,
        composition: String
    ) -> String? {
        guard case let .committed(text) = RimePinyinEngine.shared.selectCandidate(
            candidate,
            for: composition,
            commitRemainingComposition: true
        ) else {
            return nil
        }
        return text
    }

    static func markedText(for composition: String) -> String {
        if !composition.isEmpty {
            _ = RimePinyinEngine.shared.prepare()
        }
        return RimePinyinEngine.shared.markedText(for: composition)
            ?? composition
    }

    static func resetComposition() {
        RimePinyinEngine.shared.resetComposition()
    }

    private static func fallbackCandidates(
        for composition: String,
        limit: Int
    ) -> [String] {
        let key = normalizedLetters(composition)
        guard !key.isEmpty, limit > 0 else {
            return []
        }

        var results: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty, results.count < limit, seen.insert(value).inserted else {
                return
            }
            results.append(value)
        }

        priorityCandidates[key]?.forEach(append)
        phraseIndex[key]?.forEach(append)
        characterIndex[key]?.forEach { append(String($0)) }

        for segmentation in segmentations(of: key, limit: 8) {
            let choices = segmentation.compactMap { characterIndex[$0] }
            guard choices.count == segmentation.count,
                  choices.allSatisfy({ !$0.isEmpty }) else {
                continue
            }

            let primary = String(choices.compactMap(\.first))
            append(primary)

            for index in choices.indices {
                for alternative in choices[index].dropFirst().prefix(2) {
                    var combination = choices.compactMap(\.first)
                    combination[index] = alternative
                    append(String(combination))
                }
            }
        }

        if results.count < limit, key.count >= 2 {
            phraseKeys
                .lazy
                .filter { $0.hasPrefix(key) }
                .prefix(limit - results.count)
                .compactMap { phraseIndex[$0]?.first }
                .forEach(append)
        }

        return results
    }

    private static func fallbackCandidatePage(
        for composition: String,
        offset: Int,
        limit: Int
    ) -> PinyinCandidatePage {
        guard offset >= 0, limit > 0 else {
            return PinyinCandidatePage(
                candidates: [],
                hasMore: false,
                nextOffset: max(0, offset)
            )
        }

        let requestedCount = offset + limit + 1
        let candidates = fallbackCandidates(
            for: composition,
            limit: requestedCount
        )
        guard offset < candidates.count else {
            return PinyinCandidatePage(
                candidates: [],
                hasMore: false,
                nextOffset: offset
            )
        }

        let endIndex = min(offset + limit, candidates.count)
        return PinyinCandidatePage(
            candidates: Array(candidates[offset..<endIndex]),
            hasMore: endIndex < candidates.count,
            nextOffset: endIndex
        )
    }

    private static let characterIndex: [String: String] = {
        var index: [String: String] = [:]
        var seenCharacters = Set<Character>()

        for character in commonCharacters where seenCharacters.insert(character).inserted {
            let key = romanized(String(character))
            guard !key.isEmpty else {
                continue
            }
            index[key, default: ""].append(character)
        }

        // The hand-ranked list above keeps common candidates near the front, but
        // it is intentionally small. Index the complete basic CJK ranges as a
        // fallback so a valid syllable never stops at the few characters present
        // in that list (for example, "gou" also needs 狗、勾、沟、钩 and more).
        for range in [0x4E00...0x9FFF, 0x3400...0x4DBF] {
            for scalarValue in range {
                guard let scalar = UnicodeScalar(scalarValue) else {
                    continue
                }
                let character = Character(scalar)
                guard seenCharacters.insert(character).inserted else {
                    continue
                }
                let value = String(character)
                let key = romanized(value)
                guard !key.isEmpty else {
                    continue
                }
                index[key, default: ""].append(character)
            }
        }

        return index
    }()

    // Small per-syllable overrides handle the most visible frequency ordering.
    // The general common-character list and complete CJK fallback supply the rest.
    private static let priorityCandidates: [String: [String]] = [
        "gou": ["狗", "够", "购", "构", "沟", "勾", "钩", "苟", "垢", "篝", "佝", "媾"]
    ]

    private static let phraseIndex: [String: [String]] = {
        var index: [String: [String]] = [:]

        for phrase in commonPhrases.split(whereSeparator: \.isWhitespace).map(String.init) {
            let key = romanized(phrase)
            guard !key.isEmpty,
                  !(index[key]?.contains(phrase) ?? false) else {
                continue
            }
            index[key, default: []].append(phrase)
        }

        return index
    }()

    private static let phraseKeys: [String] = {
        phraseIndex.keys.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count < rhs.count
        }
    }()

    private static let knownSyllables: [String] = {
        characterIndex.keys.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }
    }()

    private static func segmentations(of key: String, limit: Int) -> [[String]] {
        var cache: [Int: [[String]]] = [:]

        func solve(_ offset: Int) -> [[String]] {
            if offset == key.count {
                return [[]]
            }
            if let cached = cache[offset] {
                return cached
            }

            let start = key.index(key.startIndex, offsetBy: offset)
            let suffix = key[start...]
            var results: [[String]] = []

            for syllable in knownSyllables where suffix.hasPrefix(syllable) {
                for tail in solve(offset + syllable.count) {
                    results.append([syllable] + tail)
                    if results.count >= limit {
                        cache[offset] = results
                        return results
                    }
                }
            }

            cache[offset] = results
            return results
        }

        return solve(0)
    }

    private static func romanized(_ text: String) -> String {
        let mutable = NSMutableString(string: text)
        CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
        CFStringTransform(mutable, nil, kCFStringTransformStripDiacritics, false)
        return normalizedLetters(mutable as String)
    }

    private static func normalizedLetters(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap { scalar in
            guard (97...122).contains(scalar.value) else {
                return nil
            }
            return String(scalar)
        }.joined()
    }

    // The order is intentional: more common characters become earlier candidates.
    private static let commonCharacters = """
    的一是不了在人有我他这个们中来上大为和国地到以说时要就出会可也你对生能而子那得于着下自之年过发后作里用道行所然家种事成方多经么去法学如都同现当没动面起看定天分还进好小部其些主样理心她本前开但因只从想实日军者意无力它与长把机十民第公此已工使情明性知全三又关点正业外将两高间由问很最重并物手应战向头文体政美相见被利什二等产或新己制身果加西斯月话合回特代内信表化老给世位次度门任常先海通教儿原东声提立及比员解水名真论处走义各入几口认条平系气题活尔更别打女变四神总何电数安少报才结反受目太量再感建务做接必场件计管期市直德资命山金指克许统区保至队形社便空决治展马科司五基眼书非则听白却界达光放强即像难且权思王象完设式色路记南品住告类求据程北边死张该交规万取拉格望觉术领共确传师观清今切院让识候带导争运笑飞风步改收根干造言联持组每济车亲极林服快办议往元英士证近失转夫令准布始怎呢存未远叫台单影具罗字爱击流备兵连调深商算质团集百需价花党华城石级整府离况亚请技际约示复病息究线似官火断精满支视消越器容照须九增研写称企八功吗包片史委乎查轻易早曾除农找装广显吧阿李标谈吃图念六引历首医局突专费号尽另周较注语仅考落青随选列武红响虽推势参希古众构房半节土投某案黑维革划敌致陈律足态护七兴派孩验责营星够章音跟志底站严巴例防族供效续施留讲型料终答紧黄绝奇察母京段依批群项故按河米围江织害斗双境客纪采举杀攻父苏密低朝友诉止细愿千值仍男钱破网热助倒育属坐帝限船脸职速刻乐否刚威毛状率甚独球般普怕弹校苦创假久错承印晚兰试股拿脑预谁益阳若哪微尼继送急血惊伤素药适波夜省初喜卫源食险待述陆习置居劳财环排福纳欢雷警获模充负云停木游龙树疑层冷洲冲射略范竟句室异激汉村策演简卡罪判担州静退既衣您宗积余痛检差富灵协角占配征修皮挥胜降阶审沉坚善妈刘读啊超免压银买皇养伊怀执副乱抗犯追帮宣佛岁航优怪香著田铁控税左右份穿艺背阵草脚概恶块顿敢守酒岛托央户烈洋哥索胡款靠评版宝座释景顾弟登货互付慢欧换闻危忙核暗姐介坏讨丽良序升监临亮露永呼味野架域沙掉括舰鱼杂误湾吉减编楚肯测败屋跑梦散温困剑渐封救贵枪缺楼县尚毫移娘朋画班智亦耳恩短掌恐遗固席松秘谢遇康虑幸均销钟诗藏赶剧票损忽巨炮旧端探湖录叶春乡附吸予礼港雨呀板庭妇归睛饭额含顺输摇招婚脱补督油疗旅泽材灭逐莫笔亡鲜词圣择寻厂睡博烟授诺伦岸奥唐卖俄炸载健堂旁宫喝借君禁阴园谋宋避抓荣姑孙逃牙束跳顶玉镇雪午练迫爷篇肉嘴馆遍凡础洞卷坦牛宁纸诸训私庄祖丝翻暴森塔默握戏隐熟骨访弱蒙歌店鬼软典欲伙遭盘爸扩盖弄雄稳忘亿刺拥徒杨齐赛趣曲刀床迎冰虚玩析窗醒妻透购替塞努休虎扬途侵刑绿兄迅套贸毕唯谷轮库迹尤竞街促延毁胸忍抽乔
    """

    private static let commonPhrases = """
    你好 您好 你们 我们 他们 她们 大家 谢谢 感谢 不客气 对不起 没关系 再见
    可以 不可以 能不能 有没有 是不是 为什么 怎么样 什么 哪里 哪个 这里 那里 现在 今天 明天 昨天
    早上 中午 下午 晚上 时间 时候 事情 问题 办法 结果 开始 结束 已经 还是 但是 因为 所以 如果 然后
    需要 想要 知道 觉得 认为 看到 听到 找到 收到 发送 打开 关闭 返回 继续 确认 取消 完成 保存 删除
    输入 输出 输入法 中文 英文 拼音 键盘 空格 回车 换行 候选 文字 文本 内容 语音 录音 识别 设置 开启 关闭
    应用 软件 系统 手机 电脑 文件 图片 视频 音频 项目 功能 模块 页面 界面 按钮 用户 数据 服务 网络
    工作 学习 生活 公司 客户 产品 需求 设计 开发 测试 修复 更新 版本 代码 程序 方案 计划 任务 进度
    这个 那个 一个 一些 一下 一点 一定 一起 一直 一样 可能 应该 必须 直接 重新 目前 以后 之前 之后
    没有 不是 不要 不用 不错 不好 不同 不会 不能 不知道 没问题 没办法
    很好 好的 好吧 好像 当然 确实 其实 真的 正在 马上 立刻 稍等 等一下 辛苦了 麻烦了
    请问 请看 请确认 请稍等 请继续 请打开 请关闭 请发送 请保存 请删除 请修改
    早上好 中午好 下午好 晚上好 大家好 你好啊 谢谢你 谢谢大家 非常感谢
    AgenBoard AgentBoard Typeless Obsidian
    """
}
