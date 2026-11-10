//! Importar / exportar o backup JSON do app do Mac (Configurações → Exportar).
//!
//! O formato é o `SettingsSnapshot` do app do Mac (chaves em camelCase). A
//! importação é tolerante (chaves ausentes → padrão; abas com URL perigosa são
//! descartadas, como no Mac) e a exportação gera um arquivo que o app do Mac
//! também consegue importar de volta.

use crate::hotkey::{self, Hotkey};
use crate::model::{Direction, Settings, Tab};
use crate::urls::normalize_tab_url;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MacTab {
    id: String,
    #[serde(default)]
    title: String,
    url: String,
    #[serde(default)]
    favicon_data: Option<String>,
    #[serde(default)]
    auto_suspend_minutes: Option<u32>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MacSnapshot {
    #[serde(default)]
    tabs: Vec<MacTab>,
    width_percent: Option<f64>,
    height_percent: Option<f64>,
    vertical_offset_percent: Option<f64>,
    direction: Option<String>,
    hot_key_code: Option<i64>,
    hot_key_modifiers: Option<u64>,
    app_version: Option<String>,
    auto_suspend_enabled: Option<bool>,
    auto_suspend_minutes: Option<u32>,
}

/// Resultado de uma importação (para mostrar um resumo ao usuário).
#[derive(Debug)]
pub struct ImportReport {
    pub settings: Settings,
    pub imported_tabs: usize,
    /// Abas descartadas (URL inválida/perigosa) — "título — motivo".
    pub skipped: Vec<String>,
    /// Observações (atalho traduzido, direção desconhecida…).
    pub notes: Vec<String>,
    pub mac_version: Option<String>,
}

pub fn import_mac_backup(json: &str) -> Result<ImportReport, String> {
    let snap: MacSnapshot = serde_json::from_str(json).map_err(|e| format!("Arquivo de backup inválido: {e}"))?;

    let mut settings = Settings::default();
    let mut skipped = Vec::new();
    let mut notes = Vec::new();

    for t in snap.tabs {
        match normalize_tab_url(&t.url) {
            Some(url) => settings.tabs.push(Tab {
                id: t.id,
                title: if t.title.trim().is_empty() { url.clone() } else { t.title },
                url,
                favicon: t.favicon_data.filter(|f| !f.trim().is_empty()),
                auto_suspend_minutes: t.auto_suspend_minutes,
            }),
            None => skipped.push(format!("{} — URL não permitida ({})", t.title, t.url)),
        }
    }

    if let Some(v) = snap.width_percent { settings.width_percent = v; }
    if let Some(v) = snap.height_percent { settings.height_percent = v; }
    if let Some(v) = snap.vertical_offset_percent { settings.vertical_offset_percent = v; }

    if let Some(label) = &snap.direction {
        match Direction::from_label(label) {
            Some(d) => settings.direction = d,
            None => notes.push(format!("Direção \"{label}\" desconhecida — usando o padrão.")),
        }
    }

    if let (Some(code), Some(mods)) = (snap.hot_key_code, snap.hot_key_modifiers) {
        match hotkey::from_mac(code, mods) {
            Some(hk) => {
                settings.hotkey = hk.to_string();
                notes.push(format!("Atalho do Mac traduzido para {}.", settings.hotkey));
            }
            None => notes.push("O atalho do Mac não tem equivalente — usando Alt+Q.".to_string()),
        }
    }

    if let Some(e) = snap.auto_suspend_enabled { settings.auto_suspend_enabled = e; }
    if let Some(m) = snap.auto_suspend_minutes.filter(|m| *m > 0) { settings.auto_suspend_minutes = m; }
    // "Iniciar com o sistema" não é importado (igual ao Mac): fica a critério do usuário.

    settings.sanitize();
    Ok(ImportReport {
        imported_tabs: settings.tabs.len(),
        settings,
        skipped,
        notes,
        mac_version: snap.app_version,
    })
}

/// Junta o resultado da importação com as preferências que só existem no Linux
/// (pasta de downloads, perguntar onde salvar, iniciar com o sistema).
pub fn apply_import(current: &Settings, imported: Settings) -> Settings {
    let mut out = imported;
    out.launch_at_login = current.launch_at_login;
    out.ask_download_location = current.ask_download_location;
    out.download_dir = current.download_dir.clone();
    out.sanitize();
    out
}

// ───────────────────────────── exportação ─────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutTab<'a> {
    id: String,
    title: &'a str,
    url: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    favicon_data: Option<&'a str>,
    /// O Mac exige esta chave (não é opcional lá).
    is_suspended: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    auto_suspend_minutes: Option<u32>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OutSnapshot<'a> {
    tabs: Vec<OutTab<'a>>,
    width_percent: f64,
    height_percent: f64,
    vertical_offset_percent: f64,
    direction: &'static str,
    hot_key_code: i64,
    hot_key_modifiers: u64,
    launch_at_login: bool,
    app_version: String,
    auto_suspend_enabled: bool,
    auto_suspend_minutes: u32,
}

/// O Mac usa `UUID` no id das abas: converte ids que não sejam UUID válido em
/// um UUID determinístico (o mesmo id sempre vira o mesmo UUID).
pub fn to_uuid(id: &str) -> String {
    if is_uuid(id) {
        return id.to_string();
    }
    // FNV-1a de 128 bits sobre o texto → 16 bytes → formato UUID v4.
    let mut h: u128 = 0x6c62272e07bb014262b821756295c58d;
    for b in id.bytes() {
        h ^= u128::from(b);
        h = h.wrapping_mul(0x0000000001000000000000000000013B);
    }
    let mut b = h.to_be_bytes();
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    format_uuid(&b)
}

pub fn format_uuid(b: &[u8; 16]) -> String {
    let hex: Vec<String> = b.iter().map(|x| format!("{x:02X}")).collect();
    format!("{}-{}-{}-{}-{}", hex[0..4].concat(), hex[4..6].concat(), hex[6..8].concat(), hex[8..10].concat(), hex[10..16].concat())
}

pub fn is_uuid(s: &str) -> bool {
    let p: Vec<&str> = s.split('-').collect();
    p.len() == 5
        && [8usize, 4, 4, 4, 12].iter().zip(&p).all(|(n, part)| part.len() == *n && part.bytes().all(|c| c.is_ascii_hexdigit()))
}

/// Gera o JSON no formato do app do Mac.
pub fn export_mac_backup(s: &Settings) -> String {
    let (code, mods) = Hotkey::parse(&s.hotkey)
        .and_then(|hk| hotkey::to_mac(&hk))
        .unwrap_or((12, 2048)); // Option+Q
    let snap = OutSnapshot {
        tabs: s
            .tabs
            .iter()
            .map(|t| OutTab {
                id: to_uuid(&t.id),
                title: &t.title,
                url: &t.url,
                favicon_data: t.favicon.as_deref(),
                is_suspended: false,
                auto_suspend_minutes: t.auto_suspend_minutes,
            })
            .collect(),
        width_percent: s.width_percent,
        height_percent: s.height_percent,
        vertical_offset_percent: s.vertical_offset_percent,
        direction: s.direction.label(),
        hot_key_code: code,
        hot_key_modifiers: mods,
        launch_at_login: s.launch_at_login,
        app_version: format!("linux-{}", env!("CARGO_PKG_VERSION")),
        auto_suspend_enabled: s.auto_suspend_enabled,
        auto_suspend_minutes: s.auto_suspend_minutes,
    };
    serde_json::to_string_pretty(&snap).expect("serialização de estruturas simples não falha")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Backup no formato exato que o Swift (`JSONEncoder` pretty + sortedKeys) gera.
    const MAC_BACKUP: &str = r#"{
  "appVersion" : "1.7.1",
  "autoSuspendEnabled" : true,
  "autoSuspendMinutes" : 45,
  "direction" : "Direita para Esquerda",
  "heightPercent" : 0.8023012552301255,
  "hotKeyCode" : 12,
  "hotKeyModifiers" : 2048,
  "launchAtLogin" : true,
  "tabs" : [
    { "autoSuspendMinutes" : 0, "faviconData" : "iVBORw0KGgo=", "id" : "2EA4DE2D-C455-4E7B-A715-6ED7243EC203",
      "isSuspended" : false, "title" : "WhatsApp Web", "url" : "https://web.whatsapp.com" },
    { "id" : "11111111-2222-3333-4444-555555555555", "isSuspended" : true, "title" : "CasaOS", "url" : "http://192.168.0.30" },
    { "id" : "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", "isSuspended" : false, "title" : "Arquivo local", "url" : "file:///etc/passwd" },
    { "id" : "99999999-8888-7777-6666-555555555555", "isSuspended" : false, "title" : "", "url" : "notion.so" }
  ],
  "verticalOffsetPercent" : 0.100418410041841,
  "widthPercent" : 0.7156462585034014
}"#;

    #[test]
    fn importa_o_backup_do_mac() {
        let r = import_mac_backup(MAC_BACKUP).unwrap();
        let s = &r.settings;
        assert_eq!(r.mac_version.as_deref(), Some("1.7.1"));
        assert_eq!(r.imported_tabs, 3);
        assert_eq!(s.tabs[0].id, "2EA4DE2D-C455-4E7B-A715-6ED7243EC203", "ids preservados");
        assert_eq!(s.tabs[0].title, "WhatsApp Web");
        assert_eq!(s.tabs[0].url, "https://web.whatsapp.com/");
        assert_eq!(s.tabs[0].favicon.as_deref(), Some("iVBORw0KGgo="));
        assert_eq!(s.tabs[0].auto_suspend_minutes, Some(0), "política 'nunca' vem junto");
        assert_eq!(s.tabs[1].url, "http://192.168.0.30/");
        assert_eq!(s.tabs[2].url, "https://notion.so/", "sem esquema → https");
        assert_eq!(s.tabs[2].title, "https://notion.so/", "título vazio vira a URL");
        assert_eq!(r.skipped.len(), 1);
        assert!(r.skipped[0].contains("file:///etc/passwd"), "URL perigosa descartada: {:?}", r.skipped);
        assert_eq!(s.width_percent, 0.7156462585034014);
        assert_eq!(s.direction, Direction::RightToLeft);
        assert_eq!(s.hotkey, "Alt+Q", "Option+Q do Mac → Alt+Q");
        assert!(s.auto_suspend_enabled && s.auto_suspend_minutes == 45);
        assert!(!s.launch_at_login, "iniciar com o sistema não é importado");
        assert_eq!(s.selected_tab.as_deref(), Some("2EA4DE2D-C455-4E7B-A715-6ED7243EC203"));
        assert!(r.notes.iter().any(|n| n.contains("Alt+Q")));
    }

    #[test]
    fn backup_minimo_e_antigo_ainda_importa() {
        let r = import_mac_backup(r#"{"tabs":[]}"#).unwrap();
        assert_eq!(r.settings, Settings::default());
        let r = import_mac_backup(r#"{"direction":"Nada a ver","hotKeyCode":9999,"hotKeyModifiers":2048}"#).unwrap();
        assert_eq!(r.settings.direction, Direction::RightToLeft);
        assert_eq!(r.notes.len(), 2, "{:?}", r.notes);
    }

    #[test]
    fn json_invalido_da_erro_claro() {
        let e = import_mac_backup("isto não é json").unwrap_err();
        assert!(e.starts_with("Arquivo de backup inválido"), "{e}");
    }

    #[test]
    fn valores_absurdos_sao_limitados() {
        let r = import_mac_backup(r#"{"widthPercent": 50, "heightPercent": -3, "verticalOffsetPercent": 9}"#).unwrap();
        assert_eq!(r.settings.width_percent, 1.0);
        assert_eq!(r.settings.height_percent, 0.05);
        assert_eq!(r.settings.vertical_offset_percent, 0.5);
    }

    #[test]
    fn aplicar_preserva_o_que_so_existe_no_linux() {
        let mut cur = Settings::default();
        cur.launch_at_login = true;
        cur.ask_download_location = true;
        cur.download_dir = Some("/tmp/x".into());
        let imported = import_mac_backup(MAC_BACKUP).unwrap().settings;
        let out = apply_import(&cur, imported);
        assert!(out.launch_at_login && out.ask_download_location);
        assert_eq!(out.download_dir.as_deref(), Some("/tmp/x"));
        assert_eq!(out.tabs.len(), 3, "abas vêm do backup");
    }

    #[test]
    fn exportacao_tem_todas_as_chaves_que_o_mac_exige_e_volta_igual() {
        let imported = import_mac_backup(MAC_BACKUP).unwrap().settings;
        let json = export_mac_backup(&imported);
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        // chaves obrigatórias do SettingsSnapshot do Mac (Decodable sintetizado)
        for k in ["tabs", "widthPercent", "heightPercent", "verticalOffsetPercent", "direction",
                  "hotKeyCode", "hotKeyModifiers", "launchAtLogin", "appVersion"] {
            assert!(v.get(k).is_some(), "falta a chave {k}");
        }
        for t in v["tabs"].as_array().unwrap() {
            for k in ["id", "title", "url", "isSuspended"] {
                assert!(t.get(k).is_some(), "aba sem {k}");
            }
            assert!(is_uuid(t["id"].as_str().unwrap()), "o Mac exige UUID");
        }
        assert_eq!(v["hotKeyCode"], 12);
        assert_eq!(v["hotKeyModifiers"], 2048);
        assert_eq!(v["direction"], "Direita para Esquerda");
        // e nosso importador entende o que exportamos
        let back = import_mac_backup(&json).unwrap().settings;
        assert_eq!(back.tabs, imported.tabs);
        assert_eq!(back.hotkey, imported.hotkey);
        assert_eq!(back.direction, imported.direction);
    }

    #[test]
    fn uuid_deterministico_e_valido() {
        let a = to_uuid("qualquer-id-nao-uuid");
        assert!(is_uuid(&a));
        assert_eq!(a, to_uuid("qualquer-id-nao-uuid"));
        assert_ne!(a, to_uuid("outro"));
        assert_eq!(to_uuid("2EA4DE2D-C455-4E7B-A715-6ED7243EC203"), "2EA4DE2D-C455-4E7B-A715-6ED7243EC203");
        assert!(!is_uuid("1234"));
        assert!(!is_uuid("ZZZZZZZZ-ZZZZ-ZZZZ-ZZZZ-ZZZZZZZZZZZZ"));
    }

    /// Teste manual com o backup REAL (fora do repositório): rode com
    /// `EASYBAR_REAL_BACKUP=/caminho/backup.json cargo test real -- --ignored --nocapture`
    #[test]
    #[ignore]
    fn backup_real_do_usuario() {
        let path = std::env::var("EASYBAR_REAL_BACKUP").expect("defina EASYBAR_REAL_BACKUP");
        let json = std::fs::read_to_string(path).unwrap();
        let r = import_mac_backup(&json).unwrap();
        println!("abas importadas: {} · descartadas: {:?} · atalho: {} · direção: {:?}",
                 r.imported_tabs, r.skipped, r.settings.hotkey, r.settings.direction);
        assert!(r.imported_tabs > 0);
        let again = import_mac_backup(&export_mac_backup(&r.settings)).unwrap();
        assert_eq!(again.settings.tabs, r.settings.tabs, "ida e volta preserva as abas");
    }
}
