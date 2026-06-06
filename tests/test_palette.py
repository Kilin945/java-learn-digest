from palette import daily_color, PALETTE


def test_palette_has_ten_colors():
    assert len(PALETTE) == 10
    for bg, bar, txt in PALETTE:
        assert bg.startswith("#") and bar.startswith("#") and txt.startswith("#")


def test_daily_color_rotates_by_day_of_year():
    # 第 158 天（2026-06-07）→ 158 % 10 = 8
    assert daily_color(158) == PALETTE[8]
    assert daily_color(1) == PALETTE[1]
    assert daily_color(10) == PALETTE[0]
