//! Falhas de carregamento: classificação em português e a página de erro com
//! "Tentar novamente" (porte do `LoadFailurePage` do app do Mac).

/// Texto mostrado ao usuário e se vale tentar sozinho quando a rede voltar.
#[derive(Debug, PartialEq, Eq)]
pub struct FailureInfo {
    pub title: &'static str,
    pub detail: &'static str,
    /// Falha de conexão: recarregar automaticamente quando a rede voltar / o PC acordar.
    pub connectivity: bool,
}

/// Erros que NÃO são falha de verdade (cancelamento, conversão em download…) e
/// não devem gerar página de erro. `domain`: nome do domínio do GError
/// (`WebKitNetworkError`, `webkit-policy-error-quark`…).
pub fn is_ignorable(domain: &str, code: i32) -> bool {
    let d = domain.to_ascii_lowercase();
    let network = d.contains("network");
    let policy = d.contains("policy");
    // WebKitNetworkError: 302 = cancelado · WebKitPolicyError: 100/101/102 =
    // não dá para exibir (vira download) / interrompido por mudança de política.
    (network && code == 302) || (policy && (100..=102).contains(&code))
}

/// Classifica pela mensagem do libsoup/WebKit (a mais informativa; os códigos de
/// `WebKitNetworkError` são genéricos demais).
pub fn describe(message: &str) -> FailureInfo {
    let m = message.to_ascii_lowercase();
    let has = |needles: &[&str]| needles.iter().any(|n| m.contains(n));

    if has(&["network is unreachable", "no route to host", "network is down", "offline"]) {
        return FailureInfo {
            title: "Sem conexão com a internet",
            detail: "Verifique sua rede. Vou recarregar esta aba automaticamente quando a conexão voltar.",
            connectivity: true,
        };
    }
    if has(&["resolving", "name or service not known", "temporary failure in name resolution",
             "nodename nor servname", "could not resolve", "no address associated"]) {
        return FailureInfo {
            title: "Não foi possível encontrar o servidor",
            detail: "Confira o endereço e a sua conexão (ou o DNS).",
            connectivity: true,
        };
    }
    if has(&["timed out", "timeout"]) {
        return FailureInfo {
            title: "O site demorou demais para responder",
            detail: "A conexão está lenta ou o servidor não respondeu a tempo.",
            connectivity: true,
        };
    }
    if has(&["connection refused", "could not connect", "unable to connect"]) {
        return FailureInfo {
            title: "Não foi possível conectar ao servidor",
            detail: "O servidor recusou a conexão ou está fora do ar.",
            connectivity: true,
        };
    }
    if has(&["connection reset", "broken pipe", "connection terminated", "connection lost",
             "error reading from", "unexpectedly"]) {
        return FailureInfo {
            title: "A conexão foi interrompida",
            detail: "A rede caiu durante o carregamento. Vou tentar de novo quando ela voltar.",
            connectivity: true,
        };
    }
    if has(&["tls", "ssl", "certificate", "handshake"]) {
        return FailureInfo {
            title: "Falha na conexão segura (SSL/TLS)",
            detail: "Não foi possível estabelecer uma conexão segura com o site.",
            connectivity: false,
        };
    }
    FailureInfo {
        title: "Não foi possível abrir a página",
        detail: "Ocorreu um erro de rede ao carregar. Tente novamente.",
        connectivity: false,
    }
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

/// Literal de string JS seguro (via JSON) para a URL.
fn js_string(s: &str) -> String {
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".to_string())
}

/// HTML da página de erro. `tab_title` vira o `<title>` (assim o título salvo da
/// aba não é trocado por "Falha ao carregar").
pub fn page_html(url: &str, host: &str, tab_title: &str, info: &FailureInfo, technical: &str) -> String {
    // O JS vai dentro de um atributo HTML entre aspas → escapa também para HTML.
    let onclick = esc(&format!("window.location.replace({})", js_string(url)));
    format!(
        r#"<!doctype html><html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title_tag}</title>
<style>
  :root {{ color-scheme: light dark; }}
  html, body {{ height: 100%; margin: 0; }}
  body {{ display: flex; align-items: center; justify-content: center;
         font: 15px system-ui, sans-serif; background: Canvas; color: CanvasText; }}
  .card {{ max-width: 460px; padding: 32px; text-align: center; }}
  .icon {{ font-size: 44px; }}
  h1 {{ font-size: 20px; margin: 10px 0 6px; }}
  p {{ opacity: .75; line-height: 1.45; margin: 6px 0; }}
  .host {{ font-weight: 600; opacity: 1; }}
  code {{ font-size: 11.5px; opacity: .55; word-break: break-word; }}
  button {{ margin-top: 18px; font: inherit; padding: 9px 20px; border: 0; border-radius: 9px;
           background: #0a84ff; color: #fff; cursor: pointer; }}
  button:hover {{ filter: brightness(1.1); }}
</style></head><body><div class="card">
  <div class="icon">⚠️</div>
  <h1>{title}</h1>
  <p class="host">{host}</p>
  <p>{detail}</p>
  <p><code>{technical}</code></p>
  <button onclick="{onclick}">Tentar novamente</button>
</div></body></html>"#,
        title_tag = esc(tab_title),
        title = esc(info.title),
        host = esc(host),
        detail = esc(info.detail),
        technical = esc(technical),
        onclick = onclick,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ignora_cancelamento_e_conversao_em_download() {
        assert!(is_ignorable("WebKitNetworkError", 302));
        assert!(is_ignorable("webkit-network-error-quark", 302));
        assert!(is_ignorable("WebKitPolicyError", 102));
        assert!(is_ignorable("webkit-policy-error-quark", 100));
        assert!(!is_ignorable("WebKitNetworkError", 300), "transporte é falha real");
        assert!(!is_ignorable("WebKitNetworkError", 399));
        assert!(!is_ignorable("WebKitPolicyError", 103));
    }

    #[test]
    fn classifica_mensagens_do_libsoup() {
        let c = |m: &str| describe(m);
        assert_eq!(c("Error resolving 'x.invalid': Name or service not known").title, "Não foi possível encontrar o servidor");
        assert!(c("Error resolving 'x': Temporary failure in name resolution").connectivity);
        assert_eq!(c("Could not connect to 192.168.0.9: Connection refused").title, "Não foi possível conectar ao servidor");
        assert_eq!(c("Network is unreachable").title, "Sem conexão com a internet");
        assert_eq!(c("Connection timed out").title, "O site demorou demais para responder");
        assert_eq!(c("Connection reset by peer").title, "A conexão foi interrompida");
        let tls = c("TLS error: certificate verify failed");
        assert_eq!(tls.title, "Falha na conexão segura (SSL/TLS)");
        assert!(!tls.connectivity, "erro de certificado não adianta repetir sozinho");
        let other = c("alguma coisa estranha");
        assert_eq!(other.title, "Não foi possível abrir a página");
        assert!(!other.connectivity);
    }

    #[test]
    fn html_escapa_tudo_e_botao_aponta_para_a_url() {
        let info = describe("Connection refused");
        let html = page_html(r#"https://x.com/a?b="c"&d='e'"#, "x.com", "Título <b>perigoso</b>", &info, "erro <script>alert(1)</script>");
        assert!(!html.contains("<script>alert(1)</script>"), "XSS no texto técnico");
        assert!(!html.contains("<b>perigoso</b>"), "XSS no título");
        assert!(html.contains("Título &lt;b&gt;perigoso&lt;/b&gt;"));
        assert!(html.contains("Tentar novamente"));
        // o atributo onclick não pode ser quebrado por aspas da URL
        let start = html.find("onclick=\"").unwrap() + 9;
        let end = start + html[start..].find('"').unwrap();
        let onclick = &html[start..end];
        assert!(onclick.starts_with("window.location.replace(&quot;https://x.com/a?b=\\&quot;c"), "{onclick}");
        assert!(!onclick.contains('"') && !onclick.contains('\''));
    }
}
