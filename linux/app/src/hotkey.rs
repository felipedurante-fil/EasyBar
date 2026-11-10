//! Atalho global via XGrabKey (X11). Roda numa thread própria com sua conexão X;
//! os disparos chegam à thread principal por um canal consultado por timeout.

use crate::app::App;
use easybar_core::hotkey::Hotkey;
use gtk::glib;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::Duration;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{ConnectionExt, GrabMode, ModMask};
use x11rb::protocol::Event;

pub struct HotkeyService {
    cmd: mpsc::Sender<Option<Hotkey>>,
}

impl HotkeyService {
    pub fn rebind(&self, hk: Hotkey) {
        let _ = self.cmd.send(Some(hk));
    }
}

/// (Re)registra o atalho; cria o serviço na primeira chamada.
pub fn bind(app: &Rc<App>, hk: Hotkey) {
    if let Some(svc) = app.hotkey_service.borrow().as_ref() {
        svc.rebind(hk);
        return;
    }
    let (cmd_tx, cmd_rx) = mpsc::channel::<Option<Hotkey>>();
    let (fire_tx, fire_rx) = mpsc::channel::<()>();
    let (err_tx, err_rx) = mpsc::channel::<String>();
    let _ = cmd_tx.send(Some(hk));
    std::thread::spawn(move || run(cmd_rx, fire_tx, err_tx));
    *app.hotkey_service.borrow_mut() = Some(HotkeyService { cmd: cmd_tx });

    let app = app.clone();
    glib::timeout_add_local(Duration::from_millis(40), move || {
        while fire_rx.try_recv().is_ok() {
            crate::app::dbg("atalho global disparou");
            app.toggle();
        }
        while let Ok(msg) = err_rx.try_recv() {
            app.notify("EasyBar", &msg);
        }
        glib::ControlFlow::Continue
    });
}

fn keysym_for(name: &str) -> Option<u32> {
    let k = gtk::gdk::keys::Key::from_name(name);
    let v: u32 = *k;
    (v != 0).then_some(v)
}

fn run(cmd: mpsc::Receiver<Option<Hotkey>>, fire: mpsc::Sender<()>, err: mpsc::Sender<String>) {
    let Ok((conn, screen_num)) = x11rb::connect(None) else {
        let _ = err.send("Atalho global indisponível: não consegui conectar ao servidor X.".into());
        return;
    };
    let root = conn.setup().roots[screen_num].root;
    let min = conn.setup().min_keycode;
    let max = conn.setup().max_keycode;
    let Some(mapping) = conn.get_keyboard_mapping(min, max - min + 1).ok().and_then(|c| c.reply().ok()) else {
        let _ = err.send("Atalho global indisponível: sem mapa de teclado.".into());
        return;
    };
    let per = usize::from(mapping.keysyms_per_keycode);

    let keycode_of = |sym: u32| -> Option<u8> {
        mapping
            .keysyms
            .chunks(per)
            .position(|chunk| chunk.contains(&sym))
            .map(|i| min + i as u8)
    };

    // CapsLock (Lock) e NumLock (Mod2) não podem atrapalhar o atalho.
    const LOCK: u16 = 1 << 1;
    const NUMLOCK: u16 = 1 << 4;
    let variants = [0u16, LOCK, NUMLOCK, LOCK | NUMLOCK];

    let mut current: Option<(u8, u16)> = None;
    loop {
        // comandos novos?
        let mut latest = None;
        while let Ok(c) = cmd.try_recv() {
            latest = Some(c);
        }
        if let Some(Some(hk)) = latest {
            if let Some((kc, mods)) = current.take() {
                for v in variants {
                    let _ = conn.ungrab_key(kc, root, ModMask::from(mods | v));
                }
            }
            let sym = keysym_for(&hk.key);
            match sym.and_then(keycode_of) {
                Some(kc) => {
                    let mut mods = 0u16;
                    if hk.shift { mods |= 1 << 0; }
                    if hk.ctrl { mods |= 1 << 2; }
                    if hk.alt { mods |= 1 << 3; }
                    if hk.super_key { mods |= 1 << 6; }
                    let mut failed = false;
                    for v in variants {
                        let ok = conn
                            .grab_key(true, root, ModMask::from(mods | v), kc, GrabMode::ASYNC, GrabMode::ASYNC)
                            .ok()
                            .and_then(|c| c.check().ok());
                        failed |= ok.is_none();
                    }
                    let _ = conn.flush();
                    crate::app::dbg_thread(format!("atalho {hk}: keycode={kc} mods={mods:#x} registrado={}", !failed));
                    if failed {
                        let _ = err.send(format!(
                            "Não consegui registrar o atalho {hk}: outro programa já o usa. Troque-o em Configurações (ou use o comando `easybar --toggle` como atalho do sistema)."
                        ));
                    } else {
                        current = Some((kc, mods));
                    }
                }
                None => {
                    let _ = err.send(format!("A tecla do atalho {hk} não existe neste teclado."));
                }
            }
        }
        match conn.poll_for_event() {
            Ok(Some(Event::KeyPress(ev))) => {
                if let Some((kc, _)) = current {
                    if ev.detail == kc {
                        crate::app::dbg_thread("tecla do atalho pressionada (X11)");
                        let _ = fire.send(());
                    }
                }
            }
            Ok(Some(_)) => {}
            Ok(None) => std::thread::sleep(Duration::from_millis(25)),
            Err(_) => return, // conexão X caiu
        }
    }
}
