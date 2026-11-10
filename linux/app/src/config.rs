//! Caminhos (XDG) usados pelo app.

use std::path::PathBuf;

pub struct Paths {
    pub settings_file: PathBuf,
    /// Dados do WebKit (cookies, localStorage, IndexedDB…) — o que mantém você logado.
    pub web_data: PathBuf,
    /// Cache do WebKit (recriável).
    pub web_cache: PathBuf,
    pub cookies_db: PathBuf,
    pub default_downloads: PathBuf,
}

impl Paths {
    pub fn new() -> Paths {
        let config = glib::user_config_dir().join("easybar");
        let data = glib::user_data_dir().join("easybar");
        let cache = glib::user_cache_dir().join("easybar");
        let downloads = glib::user_special_dir(glib::UserDirectory::Downloads)
            .unwrap_or_else(|| glib::home_dir().join("Downloads"))
            .join("EasyBar");
        Paths {
            settings_file: config.join("settings.json"),
            cookies_db: data.join("cookies.sqlite"),
            web_data: data.join("web"),
            web_cache: cache.join("web"),
            default_downloads: downloads,
        }
    }

    pub fn download_dir(&self, configured: Option<&str>) -> PathBuf {
        configured
            .filter(|d| !d.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| self.default_downloads.clone())
    }
}

/// Soma recursiva do tamanho dos arquivos de uma pasta (bytes).
pub fn dir_size(path: &std::path::Path) -> u64 {
    let Ok(entries) = std::fs::read_dir(path) else { return 0 };
    entries
        .flatten()
        .map(|e| match e.metadata() {
            Ok(m) if m.is_dir() => dir_size(&e.path()),
            Ok(m) => m.len(),
            Err(_) => 0,
        })
        .sum()
}

pub fn human_size(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = bytes as f64;
    let mut i = 0;
    while v >= 1024.0 && i < UNITS.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 { format!("{bytes} B") } else { format!("{v:.1} {}", UNITS[i]) }
}
