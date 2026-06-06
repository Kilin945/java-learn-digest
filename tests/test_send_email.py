import send_email as se


def test_load_config_reads_file_and_env(tmp_path, monkeypatch):
    cfg = tmp_path / "config.env"
    cfg.write_text('GMAIL_USER="a@gmail.com"\nKEYCHAIN_SERVICE="java-learn-gmail"\n', encoding="utf-8")
    monkeypatch.setattr(se, "_CONFIG_PATH", str(cfg))
    monkeypatch.delenv("GMAIL_USER", raising=False)
    monkeypatch.delenv("MAIL_TO", raising=False)
    conf = se.load_config()
    assert conf["GMAIL_USER"] == "a@gmail.com"
    assert conf["MAIL_TO"] == "a@gmail.com"          # 未設 MAIL_TO → 回退成寄給自己
    assert conf["KEYCHAIN_SERVICE"] == "java-learn-gmail"


def test_env_overrides_file(tmp_path, monkeypatch):
    cfg = tmp_path / "config.env"
    cfg.write_text('GMAIL_USER="file@gmail.com"\n', encoding="utf-8")
    monkeypatch.setattr(se, "_CONFIG_PATH", str(cfg))
    monkeypatch.setenv("GMAIL_USER", "env@gmail.com")
    assert se.load_config()["GMAIL_USER"] == "env@gmail.com"
