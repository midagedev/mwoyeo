import CoreGraphics

/// Recorded line boxes of every block of two reads, from the render traces (`ocr-block` lines).
enum ColumnBreakRecorded {
    /// arXiv 1706.03762, page 14 crop 1 (the attention figure: words turned on their side, listed bottom to top): blocks whose lines
    /// climb and hold nothing. /tmp/lead-final/b113/main-paper/p14-c1.err.
    static let rotated1706: [[CGRect]] = [
        [CGRect(x: 330, y: 896, width: 23, height: 47), CGRect(x: 370, y: 896, width: 21, height: 49), CGRect(x: 406, y: 898, width: 21, height: 40)],
        [CGRect(x: 446, y: 896, width: 19, height: 68), CGRect(x: 482, y: 898, width: 23, height: 30), CGRect(x: 517, y: 893, width: 26, height: 86)],
        [CGRect(x: 593, y: 896, width: 23, height: 40), CGRect(x: 631, y: 898, width: 23, height: 28)],
        [CGRect(x: 668, y: 898, width: 27, height: 123), CGRect(x: 707, y: 898, width: 23, height: 78), CGRect(x: 745, y: 898, width: 23, height: 30), CGRect(x: 782, y: 894, width: 27, height: 50)],
        [CGRect(x: 859, y: 898, width: 21, height: 42)],
        [CGRect(x: 935, y: 896, width: 21, height: 59), CGRect(x: 976, y: 898, width: 19, height: 35)],
        [CGRect(x: 1014, y: 898, width: 19, height: 37), CGRect(x: 1045, y: 897, width: 28, height: 88)],
        [CGRect(x: 895, y: 898, width: 23, height: 23)],
        [CGRect(x: 1099, y: 898, width: 14, height: 11)],
        [CGRect(x: 1120, y: 896, width: 28, height: 28), CGRect(x: 1163, y: 896, width: 26, height: 40), CGRect(x: 1196, y: 896, width: 28, height: 87)],
        [CGRect(x: 1272, y: 898, width: 21, height: 85)],
        [CGRect(x: 1311, y: 898, width: 25, height: 76)],
        [CGRect(x: 570, y: 628, width: 16, height: 11)],
        [CGRect(x: 631, y: 611, width: 23, height: 30), CGRect(x: 669, y: 516, width: 26, height: 123), CGRect(x: 707, y: 561, width: 23, height: 78), CGRect(x: 745, y: 609, width: 23, height: 30)],
        [CGRect(x: 782, y: 593, width: 28, height: 53)],
        [CGRect(x: 859, y: 595, width: 23, height: 47)],
        [CGRect(x: 895, y: 618, width: 23, height: 23)],
        [CGRect(x: 935, y: 580, width: 21, height: 61), CGRect(x: 976, y: 604, width: 19, height: 37)],
        [CGRect(x: 1014, y: 599, width: 19, height: 40), CGRect(x: 1043, y: 550, width: 33, height: 90)],
        [CGRect(x: 1097, y: 618, width: 47, height: 23)],
        [CGRect(x: 1161, y: 602, width: 28, height: 40), CGRect(x: 1196, y: 557, width: 26, height: 85)],
        [CGRect(x: 1272, y: 557, width: 23, height: 85)],
        [CGRect(x: 1309, y: 562, width: 32, height: 80)],
        [CGRect(x: 327, y: 317, width: 23, height: 45), CGRect(x: 368, y: 317, width: 21, height: 49), CGRect(x: 403, y: 317, width: 21, height: 40)],
        [CGRect(x: 444, y: 315, width: 19, height: 66), CGRect(x: 479, y: 317, width: 21, height: 30), CGRect(x: 515, y: 310, width: 25, height: 85)],
        [CGRect(x: 591, y: 312, width: 21, height: 40), CGRect(x: 629, y: 317, width: 21, height: 28)],
        [CGRect(x: 665, y: 315, width: 24, height: 123), CGRect(x: 702, y: 315, width: 23, height: 78), CGRect(x: 740, y: 315, width: 23, height: 30), CGRect(x: 779, y: 312, width: 22, height: 51)],
        [CGRect(x: 851, y: 316, width: 26, height: 45)],
        [CGRect(x: 890, y: 317, width: 21, height: 21)],
        [CGRect(x: 928, y: 312, width: 21, height: 59), CGRect(x: 966, y: 315, width: 21, height: 37), CGRect(x: 1004, y: 315, width: 19, height: 40), CGRect(x: 1034, y: 313, width: 33, height: 90)],
        [CGRect(x: 1154, y: 312, width: 23, height: 40), CGRect(x: 1187, y: 315, width: 26, height: 82)],
        [CGRect(x: 1261, y: 317, width: 23, height: 82)],
        [CGRect(x: 1301, y: 317, width: 23, height: 71)],
        [CGRect(x: 327, y: 16, width: 23, height: 45), CGRect(x: 368, y: 14, width: 21, height: 49), CGRect(x: 403, y: 21, width: 21, height: 40), CGRect(x: 444, y: 0, width: 19, height: 61), CGRect(x: 479, y: 30, width: 21, height: 30), CGRect(x: 513, y: 0, width: 28, height: 64)],
        [CGRect(x: 591, y: 21, width: 21, height: 37)],
        [CGRect(x: 629, y: 33, width: 21, height: 35)],
        [CGRect(x: 664, y: 0, width: 26, height: 61), CGRect(x: 702, y: 0, width: 23, height: 61), CGRect(x: 740, y: 30, width: 23, height: 30), CGRect(x: 778, y: 15, width: 25, height: 52)],
        [CGRect(x: 824, y: 45, width: 11, height: 16), CGRect(x: 890, y: 40, width: 21, height: 23)],
        [CGRect(x: 1086, y: 38, width: 50, height: 26)],
        [CGRect(x: 852, y: 18, width: 21, height: 42)],
        [CGRect(x: 928, y: 4, width: 21, height: 56), CGRect(x: 968, y: 26, width: 19, height: 35), CGRect(x: 1004, y: 21, width: 19, height: 40), CGRect(x: 1040, y: 0, width: 21, height: 59)],
        [CGRect(x: 1154, y: 21, width: 26, height: 40), CGRect(x: 1187, y: 0, width: 28, height: 61)],
        [CGRect(x: 1261, y: 0, width: 23, height: 59)],
        [CGRect(x: 1301, y: 0, width: 23, height: 59)],
    ]

    /// The use-case picture d03-magazine-3col-en (main, auto): a paragraph of the first column goes on at the top of the second.
    /// Each line with the first 24 characters of its text. /tmp/lead-final/b113/main-uc/out/d03-magazine-3col-en-auto.err.
    static let magazine: [[(CGRect, String)]] = [
        [(CGRect(x: 75, y: 74, width: 1229, height: 75), "The Quiet Return of the ")],
        [(CGRect(x: 78, y: 148, width: 236, height: 34), "By Helen Marsh")],
        [(CGRect(x: 81, y: 219, width: 510, height: 35), "When the signal drops in"), (CGRect(x: 78, y: 264, width: 512, height: 36), "of a mountain pass, the "), (CGRect(x: 78, y: 308, width: 455, height: 34), "dot on a phone stops bei")],
        [(CGRect(x: 78, y: 371, width: 512, height: 31), "Hikers have noticed. Sal"), (CGRect(x: 78, y: 413, width: 512, height: 35), "maps have risen for the "), (CGRect(x: 78, y: 460, width: 515, height: 34), "row, according to the la"), (CGRect(x: 637, y: 220, width: 205, height: 31), "in the country.")],
        [(CGRect(x: 643, y: 279, width: 515, height: 36), "People want to see the w"), (CGRect(x: 643, y: 321, width: 512, height: 39), "picture,\" says one shop "), (CGRect(x: 643, y: 371, width: 512, height: 34), "screen shows you where y"), (CGRect(x: 643, y: 410, width: 492, height: 43), "map shows you where you ")],
        [(CGRect(x: 1206, y: 216, width: 515, height: 31), "The trend is not limited"), (CGRect(x: 1208, y: 264, width: 512, height: 36), "outdoors. City guides, t"), (CGRect(x: 1208, y: 308, width: 512, height: 34), "a new audience among tra"), (CGRect(x: 1208, y: 352, width: 214, height: 33), "of notifications.")],
        [(CGRect(x: 1208, y: 429, width: 463, height: 36), "Still, almost everyone c")],
    ]
}
