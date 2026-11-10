//! Modelo de dados e persistência das configurações (JSON em `~/.config/easybar/`).

use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

/// Versão do formato do arquivo de configurações (para migrações futuras).
pub const SETTINGS_VERSION: u32 = 1;

/// Opções de tempo de descarregamento oferecidas (minutos). Igual ao app do Mac.
pub const AUTO_SUSPEND_CHOICES: [u32; 9] = [1, 5, 10, 15, 30, 60, 120, 240, 480];
pub const AUTO_SUSPEND_DEFAULT: u32 = 30;

pub fn auto_suspend_label(minutes: u32) -> String {
    if minutes < 60 {
        format!("{minutes} min")
    } else if minutes % 60 == 0 {
        format!("{} h", minutes / 60)
    } else {
        format!("{minutes} min")
    }
}

/// Lado de onde o painel desliza. Os nomes em português são os do app do Mac
/// (é o que vem no arquivo de backup).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Direction {
    RightToLeft,
    LeftToRight,
    TopToBottom,
    BottomToTop,
}

impl Direction {
    pub const ALL: [Direction; 4] = [
        Direction::RightToLeft,
        Direction::LeftToRight,
        Direction::TopToBottom,
        Direction::BottomToTop,
    ];

    /// Rótulo em português — idêntico ao `rawValue` do Mac.
    pub fn label(self) -> &'static str {
        match self {
            Direction::RightToLeft => "Direita para Esquerda",
            Direction::LeftToRight => "Esquerda para Direita",
            Direction::TopToBottom => "De Cima para Baixo",
            Direction::BottomToTop => "De Baixo para Cima",
        }
    }

    pub fn from_label(s: &str) -> Option<Direction> {
        Direction::ALL.into_iter().find(|d| d.label() == s)
    }
}

/// Uma aba (site).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Tab {
    pub id: String,
    pub title: String,
    pub url: String,
    /// Ícone do site (imagem em base64: PNG, ICO, JPEG…), se houver.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub favicon: Option<String>,
    /// Descarregamento automático só desta aba: `None` = padrão global,
    /// `Some(0)` = nunca, `Some(n)` = após n minutos.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub auto_suspend_minutes: Option<u32>,
}

impl Tab {
    pub fn new(title: impl Into<String>, url: impl Into<String>) -> Tab {
        Tab {
            id: new_id(),
            title: title.into(),
            url: url.into(),
            favicon: None,
            auto_suspend_minutes: None,
        }
    }
}

/// Identificador único no formato UUID v4 (o app do Mac exige `UUID` no id das
/// abas, então ids no mesmo formato permitem exportar de volta sem conversão).
pub fn new_id() -> String {
    use std::collections::hash_map::RandomState;
    use std::hash::{BuildHasher, Hasher};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    let mut bytes = [0u8; 16];
    for half in 0..2u8 {
        // RandomState é semeado aleatoriamente pelo sistema a cada instância.
        let mut h = RandomState::new().build_hasher();
        h.write_u64(n);
        h.write_u128(nanos);
        h.write_u8(half);
        let i = usize::from(half) * 8;
        bytes[i..i + 8].copy_from_slice(&h.finish().to_be_bytes());
    }
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    crate::backup::format_uuid(&bytes)
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    pub version: u32,
    pub tabs: Vec<Tab>,
    pub selected_tab: Option<String>,
    pub direction: Direction,
    /// Largura/altura do painel como fração do monitor (0.01–1.0).
    pub width_percent: f64,
    pub height_percent: f64,
    /// Distância do topo (0.0–0.5) para painéis laterais.
    pub vertical_offset_percent: f64,
    /// Atalho global, no formato "Alt+Q".
    pub hotkey: String,
    pub launch_at_login: bool,
    pub auto_suspend_enabled: bool,
    pub auto_suspend_minutes: u32,
    /// Pergunta onde salvar cada download.
    pub ask_download_location: bool,
    /// Pasta de downloads; `None` = `~/Downloads/EasyBar`.
    pub download_dir: Option<String>,
    /// User-Agent personalizado (avançado); `None` = o padrão do WebKitGTK.
    pub user_agent: Option<String>,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            version: SETTINGS_VERSION,
            tabs: Vec::new(),
            selected_tab: None,
            direction: Direction::RightToLeft,
            width_percent: 0.70,
            height_percent: 0.80,
            vertical_offset_percent: 0.10,
            hotkey: "Alt+Q".to_string(),
            launch_at_login: false,
            auto_suspend_enabled: true,
            auto_suspend_minutes: AUTO_SUSPEND_DEFAULT,
            ask_download_location: false,
            download_dir: None,
            user_agent: None,
        }
    }
}

impl Settings {
    /// Ajusta valores fora de faixa (arquivo editado à mão, backup estranho…).
    pub fn sanitize(&mut self) {
        self.width_percent = self.width_percent.clamp(0.05, 1.0);
        self.height_percent = self.height_percent.clamp(0.05, 1.0);
        self.vertical_offset_percent = self.vertical_offset_percent.clamp(0.0, 0.5);
        if self.auto_suspend_minutes == 0 {
            self.auto_suspend_minutes = AUTO_SUSPEND_DEFAULT;
        }
        if self
            .selected_tab
            .as_ref()
            .map_or(true, |id| !self.tabs.iter().any(|t| &t.id == id))
        {
            self.selected_tab = self.tabs.first().map(|t| t.id.clone());
        }
    }

    pub fn tab(&self, id: &str) -> Option<&Tab> {
        self.tabs.iter().find(|t| t.id == id)
    }

    pub fn tab_mut(&mut self, id: &str) -> Option<&mut Tab> {
        self.tabs.iter_mut().find(|t| t.id == id)
    }

    /// Carrega do disco; arquivo ausente → padrões; arquivo corrompido → erro
    /// (o chamador decide se avisa e usa os padrões).
    pub fn load(path: &Path) -> Result<Settings, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let mut s: Settings = serde_json::from_str(&text)
                    .map_err(|e| format!("{}: {e}", path.display()))?;
                s.sanitize();
                Ok(s)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Settings::default()),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    /// Grava de forma atômica (arquivo temporário + rename): uma queda no meio
    /// da escrita nunca deixa o arquivo de configurações pela metade.
    pub fn save(&self, path: &Path) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        }
        let tmp = path.with_extension("json.tmp");
        let text = serde_json::to_string_pretty(self).map_err(|e| e.to_string())?;
        std::fs::write(&tmp, text).map_err(|e| format!("{}: {e}", tmp.display()))?;
        std::fs::rename(&tmp, path).map_err(|e| format!("{}: {e}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp_dir(name: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("easybar-test-{name}-{}", new_id()));
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn ids_sao_unicos_e_no_formato_uuid() {
        let a = new_id();
        let b = new_id();
        assert_ne!(a, b);
        assert!(crate::backup::is_uuid(&a), "{a}");
        let many: std::collections::HashSet<String> = (0..2000).map(|_| new_id()).collect();
        assert_eq!(many.len(), 2000, "sem colisões");
    }

    #[test]
    fn rotulos_de_direcao_batem_com_o_mac() {
        assert_eq!(Direction::RightToLeft.label(), "Direita para Esquerda");
        assert_eq!(Direction::from_label("De Cima para Baixo"), Some(Direction::TopToBottom));
        assert_eq!(Direction::from_label("nada"), None);
        for d in Direction::ALL {
            assert_eq!(Direction::from_label(d.label()), Some(d));
        }
    }

    #[test]
    fn rotulo_de_tempo() {
        assert_eq!(auto_suspend_label(1), "1 min");
        assert_eq!(auto_suspend_label(30), "30 min");
        assert_eq!(auto_suspend_label(120), "2 h");
        assert_eq!(auto_suspend_label(90), "90 min");
    }

    #[test]
    fn salvar_e_carregar_ida_e_volta() {
        let dir = tmp_dir("roundtrip");
        let path = dir.join("settings.json");
        let mut s = Settings::default();
        let mut t = Tab::new("Gemini", "https://gemini.google.com");
        t.auto_suspend_minutes = Some(0);
        t.favicon = Some("QUJD".into());
        s.selected_tab = Some(t.id.clone());
        s.tabs.push(t);
        s.hotkey = "Ctrl+Shift+E".into();
        s.save(&path).unwrap();
        assert!(!path.with_extension("json.tmp").exists(), "temporário deve sumir após o rename");
        let back = Settings::load(&path).unwrap();
        assert_eq!(back, s);
    }

    #[test]
    fn arquivo_ausente_vira_padrao_e_corrompido_e_erro() {
        let dir = tmp_dir("missing");
        assert_eq!(Settings::load(&dir.join("nao-existe.json")).unwrap(), Settings::default());
        let bad = dir.join("ruim.json");
        std::fs::write(&bad, "{ isto não é json").unwrap();
        assert!(Settings::load(&bad).is_err());
    }

    #[test]
    fn chaves_desconhecidas_e_ausentes_sao_toleradas() {
        let dir = tmp_dir("tolerant");
        let path = dir.join("s.json");
        std::fs::write(&path, r#"{"width_percent": 0.5, "campo_novo_do_futuro": 1, "tabs": [
            {"id":"a","title":"A","url":"https://a.com"}]}"#).unwrap();
        let s = Settings::load(&path).unwrap();
        assert_eq!(s.width_percent, 0.5);
        assert_eq!(s.height_percent, 0.80, "ausente → padrão");
        assert_eq!(s.tabs.len(), 1);
        assert_eq!(s.selected_tab.as_deref(), Some("a"), "sanitize escolhe a primeira aba");
    }

    #[test]
    fn sanitize_corrige_valores_absurdos() {
        let mut s = Settings { width_percent: 9.0, height_percent: -1.0, vertical_offset_percent: 3.0,
                               auto_suspend_minutes: 0, ..Settings::default() };
        s.sanitize();
        assert_eq!(s.width_percent, 1.0);
        assert_eq!(s.height_percent, 0.05);
        assert_eq!(s.vertical_offset_percent, 0.5);
        assert_eq!(s.auto_suspend_minutes, AUTO_SUSPEND_DEFAULT);
    }
}
