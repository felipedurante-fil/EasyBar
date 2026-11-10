//! Segurança de URLs e nomes de arquivo — porte das regras do app do Mac
//! (`isLocalNetworkAddress`, `registrableDomain`, `normalizedWebTabURL`,
//! `sanitizedFilename`, allowlist de esquemas externos).

use std::path::{Path, PathBuf};
use url::Url;

/// `true` só para hosts COMPROVADAMENTE na rede local: `.local`/`localhost` ou um
/// literal de IP em faixa privada/loopback/link-local. Nunca por prefixo de
/// texto (`10.evil.com`, `192.168.attacker.com` NÃO são locais).
pub fn is_local_network_address(host: &str) -> bool {
    let h = host.trim().to_ascii_lowercase();
    let h = h.trim_start_matches('[').trim_end_matches(']');
    if h == "localhost" || h.ends_with(".localhost") || h.ends_with(".local") {
        return true;
    }
    if h.contains(':') {
        return h == "::1" || h.starts_with("fe80:") || h.starts_with("fc") || h.starts_with("fd");
    }
    let octets: Vec<&str> = h.split('.').collect();
    if octets.len() != 4 {
        return false;
    }
    let mut v = [0u32; 4];
    for (i, o) in octets.iter().enumerate() {
        if o.is_empty() || o.len() > 3 || !o.bytes().all(|b| b.is_ascii_digit()) || (o.len() > 1 && o.starts_with('0')) {
            return false;
        }
        match o.parse::<u32>() {
            Ok(n) if n <= 255 => v[i] = n,
            _ => return false,
        }
    }
    matches!((v[0], v[1]), (10, _) | (127, _) | (192, 168) | (169, 254)) || (v[0] == 172 && (16..=31).contains(&v[1]))
}

const MULTI_LABEL_SUFFIXES: &[&str] = &[
    "co.uk", "org.uk", "gov.uk", "ac.uk", "me.uk", "net.uk", "sch.uk", "nhs.uk", "police.uk", "mod.uk",
    "com.br", "net.br", "org.br", "gov.br", "edu.br", "art.br", "blog.br",
    "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
    "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp",
    "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
    "co.za", "org.za", "com.mx", "org.mx", "gob.mx",
    "com.ar", "com.co", "com.pe", "com.ve", "com.uy",
    "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in",
    "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
    "com.tr", "com.sg", "com.hk", "com.tw", "com.ua", "com.my", "com.ph",
    "co.kr", "or.kr", "com.pl", "net.pl", "org.pl", "gov.pl",
    "com.ru", "net.ru", "org.ru", "com.es", "com.pt", "co.il", "com.sa",
];

/// Domínio registrável (eTLD+1): `mail.google.com` → `google.com`,
/// `a.b.bbc.co.uk` → `bbc.co.uk`.
pub fn registrable_domain(host: &str) -> String {
    let h = host.trim().trim_matches('.').to_ascii_lowercase();
    let parts: Vec<&str> = h.split('.').filter(|p| !p.is_empty()).collect();
    if parts.len() < 2 {
        return h;
    }
    let last_two = format!("{}.{}", parts[parts.len() - 2], parts[parts.len() - 1]);
    if MULTI_LABEL_SUFFIXES.contains(&last_two.as_str()) && parts.len() >= 3 {
        return parts[parts.len() - 3..].join(".");
    }
    last_two
}

/// Normaliza o que o usuário digitou numa URL de aba válida: só http/https, com
/// host. Sem esquema, usa `http://` para rede local e `https://` para o resto.
pub fn normalize_tab_url(raw: &str) -> Option<String> {
    let s = raw.trim();
    if s.is_empty() {
        return None;
    }
    let full = if s.contains("://") {
        s.to_string()
    } else {
        let mut host = s.split('/').next().unwrap_or(s);
        // remove :porta antes de classificar (não mexe em IPv6)
        if let Some(i) = host.rfind(':') {
            let (h, p) = (&host[..i], &host[i + 1..]);
            if !h.is_empty() && !h.contains(':') && !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) {
                host = h;
            }
        }
        let scheme = if is_local_network_address(host) { "http" } else { "https" };
        format!("{scheme}://{s}")
    };
    let url = Url::parse(&full).ok()?;
    match url.scheme() {
        "http" | "https" => {}
        _ => return None,
    }
    url.host_str().filter(|h| !h.is_empty())?;
    Some(url.to_string())
}

/// Conteúdo web só pode pedir para abrir fora do app esquemas de navegação.
pub fn external_scheme_allowed(scheme: &str) -> bool {
    matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https" | "mailto")
}

/// Domínios que nunca são interceptados (login, comunicação, IA…) e cujos
/// popups (OAuth) abrem dentro do app.
const AUTH_DOMAINS: &[&str] = &[
    "accounts.google.com", "google.com", "googleapis.com", "googleusercontent.com",
    "accounts.youtube.com", "login.microsoftonline.com", "login.live.com",
    "microsoftonline.com", "microsoft.com", "live.com", "appleid.apple.com", "auth0.com",
    "okta.com", "slack.com", "discord.com", "github.com", "anthropic.com", "openai.com", "proton.me",
    "web.whatsapp.com", "whatsapp.com", "whatsapp.net", "web.telegram.org", "telegram.org",
    "mail.google.com", "outlook.live.com", "outlook.com",
    "chatgpt.com", "claude.ai", "gemini.google.com", "perplexity.ai", "manus.ai", "phind.com",
    "huggingface.co", "you.com", "blackbox.ai",
    "deepl.com", "translate.google.com", "languagetool.org",
    "notion.so", "notionusercontent.com", "ticktick.com", "to-do.microsoft.com", "todoist.com",
    "keep.google.com", "trello.com", "calendar.google.com", "pomofocus.io", "linear.app",
    "open.spotify.com", "spotify.com", "music.youtube.com", "youtube.com", "play.pocketcasts.com",
    "pocketcasts.com", "lofi.co", "brain.fm",
    "stackoverflow.com", "devdocs.io", "jsonhero.io", "explainshell.com", "vercel.com",
    "netlify.com", "gchq.github.io",
    "stirlingpdf.io", "excalidraw.com", "squoosh.app", "cloudconvert.com", "tinypng.com",
    "remove.bg", "convertio.co",
    "scholar.google.com", "sci-hub.se", "libgen.is", "wikipedia.org", "wolframalpha.com",
    "vault.bitwarden.com", "bitwarden.com", "temp-mail.org", "haveibeenpwned.com", "mail.proton.me",
    "instagram.com", "x.com", "twitter.com", "reddit.com", "app.buffer.com", "buffer.com",
    "worldtimebuddy.com", "speedtest.net", "downdetector.com", "bundlephobia.com",
    "app.wallabag.it", "wallabag.it",
];

pub fn is_auth_domain(host: &str) -> bool {
    let h = host.trim().to_ascii_lowercase();
    AUTH_DOMAINS.iter().any(|d| h == *d || h.ends_with(&format!(".{d}")))
}

/// Nome de arquivo vindo do servidor (Content-Disposition) → nome seguro:
/// só o último componente, sem separadores/controle, sem arquivo oculto, ≤ ~200 bytes.
pub fn sanitize_filename(raw: &str) -> String {
    let last = raw.rsplit(|c| c == '/' || c == '\\').next().unwrap_or(raw);
    let cleaned: String = last
        .chars()
        .filter(|c| !matches!(c, '/' | '\\' | ':' | '\0') && !c.is_control())
        .collect();
    let mut name = cleaned.trim().to_string();
    if name.is_empty() || name.chars().all(|c| c == '.') {
        name = "download".to_string();
    }
    name = name.trim_start_matches('.').to_string();
    if name.is_empty() {
        name = "download".to_string();
    }
    if name.len() > 200 {
        let (stem, ext) = match name.rfind('.') {
            Some(i) if name.len() - i <= 12 => (name[..i].to_string(), name[i..].to_string()),
            _ => (name.clone(), String::new()),
        };
        let mut cut = 150.min(stem.len());
        while !stem.is_char_boundary(cut) {
            cut -= 1;
        }
        name = format!("{}{}", &stem[..cut], ext);
    }
    name
}

/// Destino em `dir` que ainda não existe: `a.pdf`, `a (1).pdf`, `a (2).pdf`…
pub fn unique_destination(dir: &Path, filename: &str) -> PathBuf {
    let safe = sanitize_filename(filename);
    let first = dir.join(&safe);
    if !first.exists() {
        return first;
    }
    let p = Path::new(&safe);
    let stem = p.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| safe.clone());
    let ext = p.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    (1u32..)
        .map(|i| dir.join(format!("{stem} ({i}){ext}")))
        .find(|c| !c.exists())
        .expect("sempre acha um nome livre")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rede_local_so_para_hosts_comprovados() {
        for h in ["192.168.1.1", "10.0.0.5", "172.16.0.1", "172.31.255.255", "127.0.0.1",
                  "169.254.1.1", "router.local", "localhost", "dev.localhost", "::1", "fe80::1", "fd00::1"] {
            assert!(is_local_network_address(h), "{h} deveria ser local");
        }
        for h in ["8.8.8.8", "1.2.3.4", "93.184.216.34", "172.32.0.1", "192.168.attacker.com",
                  "10.evil.com", "example.com", "256.1.1.1", "192.168.1", "192.168.01.1", "2001:4860::1"] {
            assert!(!is_local_network_address(h), "{h} NÃO deveria ser local");
        }
    }

    #[test]
    fn dominio_registravel() {
        assert_eq!(registrable_domain("mail.google.com"), "google.com");
        assert_eq!(registrable_domain("a.b.bbc.co.uk"), "bbc.co.uk");
        assert_eq!(registrable_domain("evil.co.uk"), "evil.co.uk");
        assert_ne!(registrable_domain("bbc.co.uk"), registrable_domain("evil.co.uk"));
        assert_eq!(registrable_domain("www.uol.com.br"), "uol.com.br");
        assert_eq!(registrable_domain("localhost"), "localhost");
    }

    #[test]
    fn normaliza_urls_de_aba() {
        assert_eq!(normalize_tab_url("web.whatsapp.com").as_deref(), Some("https://web.whatsapp.com/"));
        assert_eq!(normalize_tab_url("https://mail.google.com").as_deref(), Some("https://mail.google.com/"));
        assert_eq!(normalize_tab_url("http://192.168.0.30").as_deref(), Some("http://192.168.0.30/"));
        assert_eq!(normalize_tab_url("192.168.0.30:8181").as_deref(), Some("http://192.168.0.30:8181/"));
        assert_eq!(normalize_tab_url("felipedurante.local:3022").as_deref(), Some("http://felipedurante.local:3022/"));
        assert_eq!(normalize_tab_url("localhost:3000").as_deref(), Some("http://localhost:3000/"));
        assert_eq!(normalize_tab_url("  https://x.com/a b ").as_deref(), Some("https://x.com/a%20b"));
        for bad in ["", "   ", "file:///etc/passwd", "javascript:alert(1)", "ftp://x.com", "smb://srv/share", "data:text/html,hi"] {
            assert_eq!(normalize_tab_url(bad), None, "{bad:?} deve ser recusada");
        }
    }

    #[test]
    fn esquemas_externos_permitidos() {
        for s in ["http", "https", "mailto", "HTTPS"] { assert!(external_scheme_allowed(s)); }
        for s in ["smb", "vnc", "ftp", "file", "x-apple-reminder", "javascript"] { assert!(!external_scheme_allowed(s)); }
    }

    #[test]
    fn dominios_de_login() {
        assert!(is_auth_domain("accounts.google.com"));
        assert!(is_auth_domain("gemini.google.com"));
        assert!(is_auth_domain("media-gru1-1.cdn.whatsapp.net"));
        assert!(!is_auth_domain("evilgoogle.com"), "sufixo exige o ponto");
        assert!(!is_auth_domain("google.com.evil.io"));
    }

    #[test]
    fn nomes_de_arquivo_seguros() {
        assert_eq!(sanitize_filename("../../../.zshrc"), "zshrc");
        assert_eq!(sanitize_filename("/etc/passwd"), "passwd");
        assert_eq!(sanitize_filename("..\\..\\win.ini"), "win.ini");
        assert_eq!(sanitize_filename("a:b\0c\n.pdf"), "abc.pdf");
        assert_eq!(sanitize_filename(""), "download");
        assert_eq!(sanitize_filename("..."), "download");
        assert_eq!(sanitize_filename(".oculto.txt"), "oculto.txt");
        assert_eq!(sanitize_filename("relatório final.docx"), "relatório final.docx");
        let long = format!("{}.pdf", "á".repeat(300));
        let out = sanitize_filename(&long);
        assert!(out.len() <= 200 && out.ends_with(".pdf") && out.is_char_boundary(out.len()), "len={}", out.len());
    }

    #[test]
    fn destino_unico_nao_sobrescreve() {
        let dir = std::env::temp_dir().join(format!("easybar-dl-{}", crate::model::new_id()));
        std::fs::create_dir_all(&dir).unwrap();
        let a = unique_destination(&dir, "doc.pdf");
        assert_eq!(a, dir.join("doc.pdf"));
        std::fs::write(&a, "x").unwrap();
        let b = unique_destination(&dir, "doc.pdf");
        assert_eq!(b, dir.join("doc (1).pdf"));
        std::fs::write(&b, "x").unwrap();
        assert_eq!(unique_destination(&dir, "doc.pdf"), dir.join("doc (2).pdf"));
        assert_eq!(unique_destination(&dir, "../../escapou.txt"), dir.join("escapou.txt"), "sem path traversal");
        assert_eq!(unique_destination(&dir, "semext"), dir.join("semext"));
    }
}
