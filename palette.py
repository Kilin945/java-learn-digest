#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每日卡片配色：10 色輪換，每天 +1。"""

# (BG=底色, BAR=左側色條與重點色, TXT=徽章文字色)
PALETTE = [
    ("#eef4ff", "#5b8def", "#3b6cf6"),
    ("#ecf7ef", "#4caf72", "#1e9e57"),
    ("#f1ecfb", "#8a6bd8", "#6b3bf6"),
    ("#e8f6f5", "#2bb0a6", "#0f9b9b"),
    ("#fbf3e3", "#d99b3f", "#b9791f"),
    ("#fdeef0", "#e0738a", "#d83a5e"),
    ("#edeefb", "#6b72d6", "#5159c9"),
    ("#e8f4fb", "#3f97c9", "#2b7fb0"),
    ("#f2f6e8", "#88a83f", "#6e8c28"),
    ("#f9edf6", "#c56bb0", "#b04b9b"),
]


def daily_color(day_of_year):
    """依一年中的第幾天回傳 (bg, bar, txt)。"""
    return PALETTE[day_of_year % len(PALETTE)]
