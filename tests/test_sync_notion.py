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
