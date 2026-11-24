import sync_notion as sn


def test_properties_downgrades_to_plain_text():
    # .properties 不在 Notion 語言清單，必須降級，否則整頁 POST 400
    assert sn._norm_lang("properties") == "plain text"


def test_known_alias_maps():
    assert sn._norm_lang("yml") == "yaml"
    assert sn._norm_lang("js") == "javascript"
    assert sn._norm_lang("sh") == "shell"


def test_direct_valid_lang_passes_through():
    # _LANG_MAP 沒列但 Notion 合法的語言應直接通過
    assert sn._norm_lang("rust") == "rust"
    assert sn._norm_lang("go") == "go"


def test_unknown_lang_downgrades():
    assert sn._norm_lang("brainfuck") == "plain text"


def test_case_insensitive():
    assert sn._norm_lang("Java") == "java"
    assert sn._norm_lang("YAML") == "yaml"


# ── 新頁插入位置：最新的放最上面 ──

def _para(i):
    return {"type": "paragraph", "id": i}


def _page(i, title="2026-11-24 · x"):
    return {"type": "child_page", "id": i, "child_page": {"title": title}}


def test_top_position_after_intro_text():
    # 頁首有說明文字：插在說明文字之後、第一個子頁之前
    children = [_para("p1"), _para("p2"), _page("c1"), _page("c2")]
    assert sn.top_position(children) == {"type": "after_block", "after_block": {"id": "p2"}}


def test_top_position_page_start_when_first_block_is_page():
    assert sn.top_position([_page("c1"), _page("c2")]) == {"type": "page_start"}


def test_top_position_none_when_no_child_pages():
    # 還沒有任何子頁：照預設加在最後，接在說明文字後面
    assert sn.top_position([_para("p1")]) is None
    assert sn.top_position([]) is None


def test_child_exists_matches_same_date():
    children = [_para("p1"), _page("c1", "2026-11-24 · 舊標題")]
    assert sn.child_exists(children, "2026-11-24 · 新標題", "2026-11-24")
    assert not sn.child_exists(children, "2026-11-25 · x", "2026-11-25")
