//! EasyBar para Linux — painel deslizante com abas web (GTK3 + WebKitGTK).
//!
//! Feito em "vibe coding" (Felipe Durante + Claude) e revisado por Felipe Durante.

mod app;
mod config;
mod dialogs;
mod downloads;
mod hotkey;
mod style;
mod system;
mod tabs;
mod webdata;

use gtk::prelude::*;
use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};

/// `--background`: abre sem mostrar o painel (usado no início automático da sessão).
static BACKGROUND_START: AtomicBool = AtomicBool::new(false);

fn main() -> glib::ExitCode {
    glib::set_prgname(Some("easybar"));
    glib::set_application_name("EasyBar");

    // O painel usa posicionamento/recorte X11. Em sessões Wayland, força XWayland.
    std::env::set_var("GDK_BACKEND", "x11");

    let application = gtk::Application::new(Some(app::APP_ID), gio::ApplicationFlags::empty());
    application.add_main_option(
        "toggle",
        glib::Char::from(b't'),
        glib::OptionFlags::NONE,
        glib::OptionArg::None,
        "Mostra/esconde o painel (use como atalho do sistema)",
        None,
    );
    application.add_main_option(
        "background",
        glib::Char::from(b'b'),
        glib::OptionFlags::NONE,
        glib::OptionArg::None,
        "Inicia sem mostrar o painel",
        None,
    );

    let state: Rc<RefCell<Option<Rc<app::App>>>> = Rc::new(RefCell::new(None));

    {
        let state = state.clone();
        application.connect_startup(move |a| {
            // O painel é uma janela "solta" (não registrada no Application): sem isto o
            // GApplication encerra o processo assim que a ativação termina.
            std::mem::forget(a.hold());
            let app = app::App::new(a);
            for name in ["toggle", "show", "hide", "settings", "quit"] {
                let action = gio::SimpleAction::new(name, None);
                let app2 = app.clone();
                action.connect_activate(move |_, _| app2.run_action(name));
                a.add_action(&action);
            }
            *state.borrow_mut() = Some(app);
        });
    }
    {
        let state = state.clone();
        application.connect_activate(move |_| {
            if BACKGROUND_START.swap(false, Ordering::SeqCst) {
                return;
            }
            if let Some(app) = state.borrow().as_ref() {
                app.show_panel();
            }
        });
    }
    application.connect_handle_local_options(|a, opts| {
        if opts.contains("background") {
            BACKGROUND_START.store(true, Ordering::SeqCst);
        }
        if opts.contains("toggle") {
            if let Err(e) = a.register(gio::Cancellable::NONE) {
                eprintln!("[EasyBar] não consegui registrar o app: {e}");
                return 1;
            }
            if a.is_remote() {
                // Já há uma instância: manda ela alternar e sai.
                a.activate_action("toggle", None);
                return 0;
            }
            // Primeira instância aberta com --toggle: abre o painel normalmente.
        }
        -1
    });

    application.run()
}
