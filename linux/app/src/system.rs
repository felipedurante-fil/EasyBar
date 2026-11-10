//! Integração com o sistema: ícone na bandeja, início automático e eventos de energia.

use crate::app::App;
use gtk::glib;
use gtk::prelude::*;
use std::path::PathBuf;
use std::rc::Rc;

pub fn start(app: &Rc<App>) {
    install_tray(app);
    watch_resume(app);
    sync_autostart(&app.settings.borrow().launch_at_login);
}

// ───────────────────────── autostart ─────────────────────────

fn autostart_file() -> PathBuf {
    glib::user_config_dir().join("autostart").join("easybar.desktop")
}

pub fn sync_autostart(enabled: &bool) {
    let path = autostart_file();
    if *enabled {
        let exe = std::env::current_exe()
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "easybar".into());
        let text = format!(
            "[Desktop Entry]\nType=Application\nName=EasyBar\nComment=Painel deslizante com abas web\nExec={exe} --background\nIcon=easybar\nX-GNOME-Autostart-enabled=true\nTerminal=false\n"
        );
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Err(e) = std::fs::write(&path, text) {
            eprintln!("[EasyBar] não consegui criar o início automático: {e}");
        }
    } else {
        let _ = std::fs::remove_file(&path);
    }
}

// ───────────────────────── bandeja ─────────────────────────

/// `gtk::StatusIcon` não existe nos bindings seguros do gtk-rs 0.18 → usa a API C.
fn install_tray(app: &Rc<App>) {
    unsafe {
        let icon = gtk::ffi::gtk_status_icon_new_from_icon_name(b"easybar\0".as_ptr() as *const _);
        if icon.is_null() {
            return;
        }
        // Se o tema não tiver o ícone "easybar", cai no ícone de internet.
        let theme = gtk::IconTheme::default();
        if theme.map_or(true, |t| !t.has_icon("easybar")) {
            gtk::ffi::gtk_status_icon_set_from_icon_name(icon, b"applications-internet\0".as_ptr() as *const _);
        }
        gtk::ffi::gtk_status_icon_set_tooltip_text(icon, b"EasyBar\0".as_ptr() as *const _);
        gtk::ffi::gtk_status_icon_set_visible(icon, glib::ffi::GTRUE);

        let obj: glib::Object = glib::translate::from_glib_none(icon as *mut glib::gobject_ffi::GObject);
        // clique esquerdo → alterna
        {
            let app = app.clone();
            obj.connect_local("activate", false, move |_| {
                crate::app::dbg("bandeja: clique");
                app.toggle();
                None
            });
        }
        // clique direito → menu
        {
            let app = app.clone();
            obj.connect_local("popup-menu", false, move |args| {
                let button: u32 = args.get(1).and_then(|v| v.get().ok()).unwrap_or(0);
                let time: u32 = args.get(2).and_then(|v| v.get().ok()).unwrap_or(0);
                let menu = gtk::Menu::new();
                for (label, action) in [
                    ("Mostrar/Ocultar", "toggle"),
                    ("Configurações", "settings"),
                    ("Sair", "quit"),
                ] {
                    let item = gtk::MenuItem::with_label(label);
                    let app = app.clone();
                    item.connect_activate(move |_| app.run_action(action));
                    menu.append(&item);
                }
                menu.show_all();
                menu.popup_easy(button, time);
                None
            });
        }
        crate::app::dbg(format!("bandeja: ícone criado (tema tem 'easybar': {})", gtk::IconTheme::default().map_or(false, |t| t.has_icon("easybar"))));
        // Diagnóstico: o painel de bandeja do Cinnamon aceitou o ícone?
        let raw = icon as usize;
        glib::timeout_add_seconds_local_once(3, move || {
            let embedded = gtk::ffi::gtk_status_icon_is_embedded(raw as *mut gtk::ffi::GtkStatusIcon);
            crate::app::dbg(format!("bandeja: ícone embutido no painel = {}", embedded != 0));
        });
        // O objeto precisa viver enquanto o app viver.
        std::mem::forget(obj);
    }
}

// ───────────────────────── retomada de suspensão / rede ─────────────────────────

fn watch_resume(app: &Rc<App>) {
    // Rede voltou → recarrega abas que falharam por conexão.
    let monitor = gio::NetworkMonitor::default();
    {
        let app = app.clone();
        monitor.connect_network_changed(move |_, available| {
            if available {
                crate::tabs::retry_failed(&app);
            }
        });
    }

    // Acordou da suspensão (logind) → mesma coisa, com uma folga para a rede subir.
    let app = app.clone();
    glib::MainContext::default().spawn_local(async move {
        let Ok(conn) = gio::bus_get_future(gio::BusType::System).await else { return };
        let app2 = app.clone();
        conn.signal_subscribe(
            Some("org.freedesktop.login1"),
            Some("org.freedesktop.login1.Manager"),
            Some("PrepareForSleep"),
            Some("/org/freedesktop/login1"),
            None,
            gio::DBusSignalFlags::NONE,
            move |_, _, _, _, _, params| {
                let sleeping: bool = params.child_value(0).get().unwrap_or(true);
                if !sleeping {
                    let app = app2.clone();
                    glib::timeout_add_seconds_local_once(4, move || crate::tabs::retry_failed(&app));
                }
            },
        );
        // mantém a assinatura viva
        std::mem::forget(conn);
    });
}
