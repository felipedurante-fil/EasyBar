//! Downloads: pasta padrão (`~/Downloads/EasyBar`), nome sem sobrescrever, opção de
//! perguntar onde salvar e uma janela com o histórico ("Abrir" / "Mostrar pasta").

use crate::app::App;
use easybar_core::urls;
use gtk::prelude::*;
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use webkit2gtk::{Download, DownloadExt, WebContextExt};

#[derive(Clone, PartialEq)]
pub enum Status {
    Running,
    Done,
    Failed(String),
}

#[derive(Clone)]
pub struct Entry {
    pub name: String,
    pub path: PathBuf,
    pub status: Status,
}

#[derive(Default)]
pub struct DownloadsState {
    /// Downloads em andamento (protege todas as abas da suspensão automática).
    pub active: usize,
    pub history: Vec<Entry>,
}

pub fn connect(app: &Rc<App>) {
    let app2 = app.clone();
    app.web_context.connect_download_started(move |_, download| handle(&app2, download));
}

fn handle(app: &Rc<App>, download: &Download) {
    app.downloads.borrow_mut().active += 1;
    download.set_allow_overwrite(false);

    let index: Rc<Cell<Option<usize>>> = Rc::new(Cell::new(None));
    let error: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));

    {
        let app = app.clone();
        let index = index.clone();
        download.connect_decide_destination(move |dl, suggested| {
            let dir = {
                let s = app.settings.borrow();
                app.paths.download_dir(s.download_dir.as_deref())
            };
            if let Err(e) = std::fs::create_dir_all(&dir) {
                app.notify("Download", &format!("Não consegui criar a pasta {}: {e}", dir.display()));
            }
            let dest = urls::unique_destination(&dir, suggested);
            let ask = app.settings.borrow().ask_download_location;
            if ask {
                choose_destination(&app, dl, &dir, &dest, &index);
            } else {
                set_dest(&app, dl, &dest, &index);
            }
            true
        });
    }
    {
        let error = error.clone();
        download.connect_failed(move |_, e| {
            *error.borrow_mut() = Some(e.message().to_string());
        });
    }
    {
        let app = app.clone();
        let index = index.clone();
        download.connect_finished(move |_| {
            let err = error.borrow().clone();
            {
                let mut st = app.downloads.borrow_mut();
                st.active = st.active.saturating_sub(1);
                if let Some(i) = index.get() {
                    if let Some(entry) = st.history.get_mut(i) {
                        entry.status = match &err {
                            Some(e) => Status::Failed(e.clone()),
                            None => Status::Done,
                        };
                    }
                }
            }
            let name = index
                .get()
                .and_then(|i| app.downloads.borrow().history.get(i).map(|e| e.name.clone()))
                .unwrap_or_else(|| "arquivo".into());
            match err {
                None => app.notify("Download concluído", &name),
                Some(e) => app.notify("Download falhou", &format!("{name}: {e}")),
            }
        });
    }
}

fn set_dest(app: &Rc<App>, dl: &Download, dest: &Path, index: &Rc<Cell<Option<usize>>>) {
    match glib::filename_to_uri(dest, None) {
        Ok(uri) => dl.set_destination(uri.as_str()),
        Err(_) => dl.set_destination(&format!("file://{}", dest.display())),
    }
    let mut st = app.downloads.borrow_mut();
    st.history.push(Entry {
        name: dest.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        path: dest.to_path_buf(),
        status: Status::Running,
    });
    index.set(Some(st.history.len() - 1));
}

fn choose_destination(app: &Rc<App>, dl: &Download, dir: &Path, dest: &Path, index: &Rc<Cell<Option<usize>>>) {
    let chooser = gtk::FileChooserNative::new(
        Some("Salvar arquivo"),
        None::<&gtk::Window>,
        gtk::FileChooserAction::Save,
        Some("Salvar"),
        Some("Cancelar"),
    );
    let _ = chooser.set_current_folder(dir);
    if let Some(name) = dest.file_name() {
        chooser.set_current_name(&name.to_string_lossy());
    }
    chooser.set_do_overwrite_confirmation(true);
    let app = app.clone();
    let dl = dl.clone();
    let index = index.clone();
    let keep = RefCell::new(Some(chooser.clone()));
    chooser.connect_response(move |c, resp| {
        if resp == gtk::ResponseType::Accept {
            if let Some(path) = c.filename() {
                // o usuário já confirmou a sobrescrita no diálogo
                dl.set_allow_overwrite(true);
                set_dest(&app, &dl, &path, &index);
            } else {
                dl.cancel();
            }
        } else {
            dl.cancel();
        }
        keep.borrow_mut().take(); // libera o diálogo
    });
    chooser.show();
}

// ───────────────────────── janela de downloads ─────────────────────────

pub fn show_window(app: &Rc<App>) {
    let win = gtk::Window::new(gtk::WindowType::Toplevel);
    win.set_title("Downloads — EasyBar");
    win.set_default_size(520, 420);
    win.set_keep_above(true);
    win.set_position(gtk::WindowPosition::Center);

    let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
    root.set_border_width(12);

    let dir = {
        let s = app.settings.borrow();
        app.paths.download_dir(s.download_dir.as_deref())
    };
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let where_label = gtk::Label::new(Some(&format!("Pasta: {}", dir.display())));
    where_label.set_xalign(0.0);
    where_label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    top.pack_start(&where_label, true, true, 0);
    let open_dir = gtk::Button::with_label("Abrir pasta");
    {
        let dir = dir.clone();
        open_dir.connect_clicked(move |_| {
            let _ = std::fs::create_dir_all(&dir);
            open_path(&dir);
        });
    }
    top.pack_end(&open_dir, false, false, 0);
    root.pack_start(&top, false, false, 0);

    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    let scroll = gtk::ScrolledWindow::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
    scroll.add(&list);
    root.pack_start(&scroll, true, true, 0);

    let history: Vec<Entry> = app.downloads.borrow().history.iter().rev().cloned().collect();
    if history.is_empty() {
        let l = gtk::Label::new(Some("Nenhum download nesta sessão."));
        l.set_margin_top(24);
        list.add(&l);
    }
    for e in history {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.set_border_width(6);
        let text = gtk::Box::new(gtk::Orientation::Vertical, 2);
        let name = gtk::Label::new(Some(&e.name));
        name.set_xalign(0.0);
        name.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
        let status = match &e.status {
            Status::Running => "Baixando…".to_string(),
            Status::Done => "Concluído".to_string(),
            Status::Failed(m) => format!("Falhou: {m}"),
        };
        let st = gtk::Label::new(Some(&status));
        st.set_xalign(0.0);
        st.style_context().add_class("dim-label");
        text.pack_start(&name, false, false, 0);
        text.pack_start(&st, false, false, 0);
        row.pack_start(&text, true, true, 0);
        if e.status == Status::Done {
            let open = gtk::Button::with_label("Abrir");
            let path = e.path.clone();
            open.connect_clicked(move |_| open_path(&path));
            let show = gtk::Button::with_label("Mostrar pasta");
            let parent = e.path.parent().map(Path::to_path_buf).unwrap_or_default();
            show.connect_clicked(move |_| open_path(&parent));
            row.pack_end(&show, false, false, 0);
            row.pack_end(&open, false, false, 0);
        }
        list.add(&row);
    }

    win.add(&root);
    win.show_all();
}

pub fn open_path(path: &Path) {
    if let Ok(uri) = glib::filename_to_uri(path, None) {
        let _ = gio::AppInfo::launch_default_for_uri(uri.as_str(), gio::AppLaunchContext::NONE);
    }
}
