import Foundation

/// A whole value written as a Chinese, Japanese or Korean person's name: two
/// to five Han characters or two to four Hangul syllables, as a field holds
/// it with no space between the surname and the given name ("王秀英", "김민준").
/// Such a value led by a common surname is very likely someone's; one led by
/// none still may be, so it is put to a person rather than kept unseen.
enum EastAsianNames {
    /// Nil where `value` is no such name's shape; else whether a common surname leads it.
    static func surnamed(_ value: String) -> Bool? {
        let scalars = Array(value.trimmingCharacters(in: .whitespaces).unicodeScalars)
        if scalars.allSatisfy(isHan), (2...5).contains(scalars.count) {
            let text = String(String.UnicodeScalarView(scalars))
            // A Japanese surname of two or three characters leaves one to three for the given name.
            if let surname = japanese.first(where: { text.hasPrefix($0) }) { return text.count > surname.count && text.count - surname.count <= 3 }
            guard scalars.count <= 4 else { return false }
            if compound.contains(where: { text.hasPrefix($0) }) { return scalars.count >= 3 }
            return scalars.count <= 3 && chinese.contains(scalars[0])
        }
        if scalars.allSatisfy(isHangul), (2...4).contains(scalars.count) {
            let text = String(String.UnicodeScalarView(scalars))
            if koreanCompound.contains(where: { text.hasPrefix($0) }) { return scalars.count >= 3 }
            return scalars.count <= 3 && korean.contains(scalars[0])
        }
        return nil
    }
    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value) || scalar == "々"
    }
    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool { (0xAC00...0xD7A3).contains(scalar.value) }

    /// The commonest Chinese surnames, in simplified and traditional characters, less those
    /// that open everyday words as often ("方案", "程序", "任务", "余额", "金额").
    private static let chinese: Set<Unicode.Scalar> = Set("""
    王李张刘陈杨黄赵吴周徐孙马朱胡郭何林罗郑梁谢宋唐许韩邓冯曹彭曾肖田董潘袁蔡蒋杜叶魏苏吕丁卢姚沈钟姜崔谭陆范汪廖韦贾夏邹熊孟秦邱侯江尹薛闫段雷龙黎史陶贺毛郝顾龚邵覃钱戴严莫孔汤
    張劉陳楊黃趙吳孫馬郭羅鄭謝許韓鄧馮蕭葉蘇呂盧鍾譚陸賈韋鄒龔錢嚴湯顧蔣
    """.unicodeScalars.filter { !$0.properties.isWhitespace })
    private static let compound = ["欧阳", "歐陽", "司马", "司馬", "诸葛", "諸葛", "上官", "司徒", "东方", "東方", "夏侯", "皇甫", "尉迟", "尉遲", "公孙", "公孫", "慕容", "令狐", "宇文", "长孙", "長孫", "端木"]
    /// The commonest Japanese surnames, which seldom open any other word.
    private static let japanese = ["佐藤", "鈴木", "高橋", "田中", "伊藤", "渡辺", "渡邉", "渡邊", "山本", "中村", "小林", "加藤", "吉田", "山田", "佐々木", "山口", "松本", "井上", "木村", "斎藤", "斉藤", "清水",
                                   "山崎", "池田", "橋本", "阿部", "石川", "山下", "中島", "石井", "小川", "前田", "岡田", "長谷川", "藤田", "後藤", "近藤", "村上", "遠藤", "青木", "坂本", "福田", "太田", "西村",
                                   "藤井", "岡本", "藤原", "中野", "三浦", "原田", "中川", "松田", "竹内", "小野", "田村", "中山", "和田", "石田", "森田", "上田", "柴田", "酒井", "工藤", "横山", "宮崎", "宮本",
                                   "内田", "高木", "安藤", "島田", "谷口", "大野", "高田", "丸山", "今井", "河野", "藤本", "村田", "武田", "上野", "杉山", "増田", "小山", "大塚", "平野", "菅原", "久保", "松井",
                                   "千葉", "岩崎", "桜井", "木下", "野口", "松尾", "菊地", "野村", "新井"]
    /// The commonest Korean surnames.
    private static let korean: Set<Unicode.Scalar> = Set("김이박최정강조윤장임한오서신권황안송류홍".unicodeScalars)
    private static let koreanCompound = ["남궁", "황보", "제갈", "선우", "독고", "사공", "서문"]
}
