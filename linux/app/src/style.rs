//! CSS do painel (barra de abas).

use gtk::prelude::*;

const CSS: &str = r#"
.tabbar { padding: 2px 4px; }
.tabbtn { padding: 1px 3px; border-radius: 9px; }
.tabbtn label { font-size: 9px; }
.tabbtn.selected { background: alpha(@theme_selected_bg_color, 0.28); }
.tabbtn.unloaded image, .tabbtn.unloaded label { opacity: 0.45; }
"#;

pub fn install() {
    let provider = gtk::CssProvider::new();
    if provider.load_from_data(CSS.as_bytes()).is_err() {
        return;
    }
    if let Some(screen) = gtk::gdk::Screen::default() {
        gtk::StyleContext::add_provider_for_screen(&screen, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
}
