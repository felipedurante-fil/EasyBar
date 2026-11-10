//! Diálogos: abas, configurações, importar/exportar backup do Mac, boas-vindas.

use crate::app::App;
use crate::config::human_size;
use crate::webdata;
use easybar_core::backup;
use easybar_core::hotkey::Hotkey;
use easybar_core::model::{self, Direction, Tab};
use easybar_core::urls;
use gtk::prelude::*;
use std::rc::Rc;

fn base_dialog(title: &str) -> gtk::Dialog {
    let d = gtk::Dialog::new();
    d.set_title(title);
    d.set_keep_above(true);
    d.set_position(gtk::WindowPosition::Center);
    d
}

pub fn message(title: &str, text: &str, kind: gtk::MessageType) {
    let d = gtk::MessageDialog::new(None::<&gtk::Window>, gtk::DialogFlags::empty(), kind, gtk::ButtonsType::Close, title);
    d.set_secondary_text(Some(text));
    d.set_keep_above(true);
    d.connect_response(|d, _| d.close());
    d.show();
}

// ───────────────────────── abas ─────────────────────────

pub fn add_tab(app: &Rc<App>) {
    tab_form(app, None);
}

pub fn edit_tab(app: &Rc<App>, id: &str) {
    let tab = app.settings.borrow().tab(id).cloned();
    if let Some(t) = tab {
        tab_form(app, Some(t));
    }
}

fn tab_form(app: &Rc<App>, existing: Option<Tab>) {
    let editing = existing.is_some();
    let d = base_dialog(if editing { "Editar aba" } else { "Nova aba" });
    d.add_button("Cancelar", gtk::ResponseType::Cancel);
    d.add_button("Salvar", gtk::ResponseType::Accept);
    d.set_default_response(gtk::ResponseType::Accept);

    let grid = gtk::Grid::new();
    grid.set_row_spacing(8);
    grid.set_column_spacing(10);
    grid.set_border_width(14);
    let title = gtk::Entry::new();
    title.set_width_chars(34);
    title.set_activates_default(true);
    let url = gtk::Entry::new();
    url.set_activates_default(true);
    url.set_placeholder_text(Some("https://exemplo.com"));
    if let Some(t) = &existing {
        title.set_text(&t.title);
        url.set_text(&t.url);
    }
    for (i, (label, w)) in [("Nome", &title), ("Endereço", &url)].into_iter().enumerate() {
        let l = gtk::Label::new(Some(label));
        l.set_xalign(1.0);
        grid.attach(&l, 0, i as i32, 1, 1);
        grid.attach(w, 1, i as i32, 1, 1);
    }
    let error = gtk::Label::new(None);
    error.set_xalign(0.0);
    grid.attach(&error, 1, 2, 1, 1);
    d.content_area().add(&grid);

    let app = app.clone();
    d.connect_response(move |d, resp| {
        if resp != gtk::ResponseType::Accept {
            d.close();
            return;
        }
        let Some(normalized) = urls::normalize_tab_url(url.text().as_str()) else {
            error.set_text("Endereço inválido (use http:// ou https://).");
            return;
        };
        let name = title.text().trim().to_string();
        let name = if name.is_empty() { crate::app::App::host_title(&normalized) } else { name };
        match &existing {
            Some(old) => {
                let url_changed = old.url != normalized;
                if let Some(t) = app.settings.borrow_mut().tab_mut(&old.id) {
                    t.title = name;
                    t.url = normalized.clone();
                    if url_changed {
                        t.favicon = None;
                    }
                }
                app.rebuild_tab_bar();
                if url_changed {
                    crate::tabs::suspend_tab(&app, &old.id);
                    if app.selected_id().as_deref() == Some(old.id.as_str()) {
                        app.select_tab(&old.id, false);
                    }
                }
            }
            None => {
                let tab = Tab::new(name, normalized);
                let id = tab.id.clone();
                app.settings.borrow_mut().tabs.push(tab);
                app.rebuild_tab_bar();
                app.select_tab(&id, false);
            }
        }
        app.save_settings();
        d.close();
    });
    d.show_all();
}

pub fn confirm_remove_tab(app: &Rc<App>, id: &str) {
    let title = app.settings.borrow().tab(id).map(|t| t.title.clone()).unwrap_or_default();
    let d = gtk::MessageDialog::new(
        None::<&gtk::Window>,
        gtk::DialogFlags::empty(),
        gtk::MessageType::Question,
        gtk::ButtonsType::None,
        &format!("Remover a aba \"{title}\"?"),
    );
    d.set_keep_above(true);
    d.set_secondary_text(Some("Os logins do site continuam guardados; só a aba some da barra."));
    d.add_button("Cancelar", gtk::ResponseType::Cancel);
    d.add_button("Remover", gtk::ResponseType::Accept);
    let (app, id) = (app.clone(), id.to_string());
    d.connect_response(move |d, r| {
        if r == gtk::ResponseType::Accept {
            crate::tabs::remove_tab(&app, &id);
        }
        d.close();
    });
    d.show();
}

// ───────────────────────── boas-vindas ─────────────────────────

pub fn welcome(app: &Rc<App>) {
    let d = gtk::MessageDialog::new(
        None::<&gtk::Window>,
        gtk::DialogFlags::empty(),
        gtk::MessageType::Info,
        gtk::ButtonsType::None,
        "Bem-vindo ao EasyBar",
    );
    d.set_keep_above(true);
    d.set_secondary_text(Some(
        "Se você usa o EasyBar no Mac, importe o backup (Configurações → Exportar, no Mac) para trazer suas abas e preferências. \
         Os logins não migram — você entra de novo em cada site.",
    ));
    d.add_button("Começar vazio", gtk::ResponseType::Cancel);
    d.add_button("Importar backup do Mac…", gtk::ResponseType::Accept);
    let app = app.clone();
    d.connect_response(move |d, r| {
        d.close();
        if r == gtk::ResponseType::Accept {
            import_backup(&app);
        } else {
            app.show_panel();
            add_tab(&app);
        }
    });
    d.show();
}

// ───────────────────────── backup ─────────────────────────

pub fn import_backup(app: &Rc<App>) {
    let chooser = gtk::FileChooserNative::new(
        Some("Importar backup do EasyBar (Mac)"),
        None::<&gtk::Window>,
        gtk::FileChooserAction::Open,
        Some("Importar"),
        Some("Cancelar"),
    );
    let filter = gtk::FileFilter::new();
    filter.set_name(Some("Backup JSON"));
    filter.add_pattern("*.json");
    chooser.add_filter(filter);
    let app = app.clone();
    let keep = std::cell::RefCell::new(Some(chooser.clone()));
    chooser.connect_response(move |c, r| {
        if r == gtk::ResponseType::Accept {
            if let Some(path) = c.filename() {
                match std::fs::read_to_string(&path) {
                    Ok(text) => confirm_import(&app, &text),
                    Err(e) => message("Não consegui ler o arquivo", &e.to_string(), gtk::MessageType::Error),
                }
            }
        }
        keep.borrow_mut().take();
    });
    chooser.show();
}

fn confirm_import(app: &Rc<App>, json: &str) {
    let report = match backup::import_mac_backup(json) {
        Ok(r) => r,
        Err(e) => return message("Backup inválido", &e, gtk::MessageType::Error),
    };
    let mut text = format!("{} aba(s) serão importadas.", report.imported_tabs);
    if let Some(v) = &report.mac_version {
        text.push_str(&format!("\nVersão do Mac: {v}."));
    }
    for n in &report.notes {
        text.push_str(&format!("\n• {n}"));
    }
    for s in &report.skipped {
        text.push_str(&format!("\n• Ignorada: {s}"));
    }
    text.push_str("\n\nAs abas e preferências atuais serão substituídas. Continuar?");
    let d = gtk::MessageDialog::new(
        None::<&gtk::Window>,
        gtk::DialogFlags::empty(),
        gtk::MessageType::Question,
        gtk::ButtonsType::None,
        "Importar backup do Mac",
    );
    d.set_keep_above(true);
    d.set_secondary_text(Some(&text));
    d.add_button("Cancelar", gtk::ResponseType::Cancel);
    d.add_button("Importar", gtk::ResponseType::Accept);
    let app = app.clone();
    let imported = report.settings;
    d.connect_response(move |d, r| {
        if r == gtk::ResponseType::Accept {
            let merged = backup::apply_import(&app.settings.borrow(), imported.clone());
            crate::tabs::replace_all(&app, merged);
        }
        d.close();
    });
    d.show();
}

pub fn export_backup(app: &Rc<App>) {
    let chooser = gtk::FileChooserNative::new(
        Some("Exportar backup"),
        None::<&gtk::Window>,
        gtk::FileChooserAction::Save,
        Some("Salvar"),
        Some("Cancelar"),
    );
    chooser.set_current_name("EasyBar-backup.json");
    chooser.set_do_overwrite_confirmation(true);
    let app = app.clone();
    let keep = std::cell::RefCell::new(Some(chooser.clone()));
    chooser.connect_response(move |c, r| {
        if r == gtk::ResponseType::Accept {
            if let Some(path) = c.filename() {
                let json = backup::export_mac_backup(&app.settings.borrow());
                match std::fs::write(&path, json) {
                    Ok(()) => message("Backup salvo", &path.display().to_string(), gtk::MessageType::Info),
                    Err(e) => message("Não consegui salvar", &e.to_string(), gtk::MessageType::Error),
                }
            }
        }
        keep.borrow_mut().take();
    });
    chooser.show();
}

// ───────────────────────── configurações ─────────────────────────

fn section(title: &str) -> gtk::Label {
    let l = gtk::Label::new(None);
    l.set_markup(&format!("<b>{}</b>", glib::markup_escape_text(title)));
    l.set_xalign(0.0);
    l.set_margin_top(14);
    l
}

fn row(label: &str, widget: &impl IsA<gtk::Widget>) -> gtk::Box {
    let b = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    let l = gtk::Label::new(Some(label));
    l.set_xalign(0.0);
    l.set_size_request(190, -1);
    b.pack_start(&l, false, false, 0);
    b.pack_start(widget, true, true, 0);
    b
}

pub fn settings(app: &Rc<App>) {
    let d = base_dialog("Configurações — EasyBar");
    d.set_default_size(560, 640);
    d.add_button("Cancelar", gtk::ResponseType::Cancel);
    d.add_button("Salvar", gtk::ResponseType::Accept);

    let scroll = gtk::ScrolledWindow::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
    scroll.set_policy(gtk::PolicyType::Never, gtk::PolicyType::Automatic);
    let col = gtk::Box::new(gtk::Orientation::Vertical, 8);
    col.set_border_width(16);
    scroll.add(&col);
    d.content_area().pack_start(&scroll, true, true, 0);

    let s = app.settings.borrow().clone();

    // ── painel ──
    col.pack_start(&section("Painel"), false, false, 0);
    let direction = gtk::ComboBoxText::new();
    for dir in Direction::ALL {
        direction.append_text(dir.label());
    }
    direction.set_active(Direction::ALL.iter().position(|d| *d == s.direction).map(|i| i as u32));
    col.pack_start(&row("Abre a partir de", &direction), false, false, 0);

    let spin = |value: f64, min: f64, max: f64| {
        let b = gtk::SpinButton::with_range(min, max, 1.0);
        b.set_value(value);
        b
    };
    let width = spin((s.width_percent * 100.0).round(), 5.0, 100.0);
    let height = spin((s.height_percent * 100.0).round(), 5.0, 100.0);
    let offset = spin((s.vertical_offset_percent * 100.0).round(), 0.0, 50.0);
    col.pack_start(&row("Largura (% da tela)", &width), false, false, 0);
    col.pack_start(&row("Altura (% da tela)", &height), false, false, 0);
    col.pack_start(&row("Distância do topo (%)", &offset), false, false, 0);

    let hotkey = gtk::Entry::new();
    hotkey.set_text(&s.hotkey);
    hotkey.set_tooltip_text(Some("Exemplos: Alt+Q, Ctrl+Shift+E, Super+Space"));
    col.pack_start(&row("Atalho global", &hotkey), false, false, 0);
    let hotkey_msg = gtk::Label::new(None);
    hotkey_msg.set_xalign(0.0);
    col.pack_start(&hotkey_msg, false, false, 0);

    // ── sistema ──
    col.pack_start(&section("Sistema"), false, false, 0);
    let autostart = gtk::Switch::new();
    autostart.set_active(s.launch_at_login);
    autostart.set_halign(gtk::Align::Start);
    col.pack_start(&row("Abrir ao iniciar a sessão", &autostart), false, false, 0);

    // ── downloads ──
    col.pack_start(&section("Downloads"), false, false, 0);
    let ask = gtk::Switch::new();
    ask.set_active(s.ask_download_location);
    ask.set_halign(gtk::Align::Start);
    col.pack_start(&row("Perguntar onde salvar", &ask), false, false, 0);
    let dir_btn = gtk::FileChooserButton::new("Pasta de downloads", gtk::FileChooserAction::SelectFolder);
    let current_dir = app.paths.download_dir(s.download_dir.as_deref());
    let _ = std::fs::create_dir_all(&current_dir);
    let _ = dir_btn.set_current_folder(&current_dir);
    col.pack_start(&row("Pasta de downloads", &dir_btn), false, false, 0);

    // ── memória ──
    col.pack_start(&section("Economia de memória"), false, false, 0);
    let suspend = gtk::Switch::new();
    suspend.set_active(s.auto_suspend_enabled);
    suspend.set_halign(gtk::Align::Start);
    col.pack_start(&row("Descarregar abas inativas", &suspend), false, false, 0);
    let minutes = gtk::ComboBoxText::new();
    for m in model::AUTO_SUSPEND_CHOICES {
        minutes.append_text(&format!("Após {}", model::auto_suspend_label(m)));
    }
    minutes.set_active(
        model::AUTO_SUSPEND_CHOICES
            .iter()
            .position(|m| *m == s.auto_suspend_minutes)
            .map(|i| i as u32)
            .or(Some(4)),
    );
    col.pack_start(&row("Tempo padrão", &minutes), false, false, 0);
    let note = gtk::Label::new(Some(
        "A aba aberta, as que tocam áudio e as com download em andamento nunca são descarregadas. \
         Ajuste por aba com o botão direito na barra.",
    ));
    note.set_xalign(0.0);
    note.set_line_wrap(true);
    note.style_context().add_class("dim-label");
    col.pack_start(&note, false, false, 0);

    // ── navegação ──
    col.pack_start(&section("Navegação (avançado)"), false, false, 0);
    let ua = gtk::Entry::new();
    ua.set_text(s.user_agent.as_deref().unwrap_or(""));
    ua.set_placeholder_text(Some("Vazio = padrão do WebKitGTK"));
    col.pack_start(&row("User-Agent", &ua), false, false, 0);

    // ── armazenamento ──
    col.pack_start(&section("Armazenamento de navegação"), false, false, 0);
    let usage_label = gtk::Label::new(Some("Calculando o tamanho…"));
    usage_label.set_xalign(0.0);
    refresh_usage(app, &usage_label);
    col.pack_start(&usage_label, false, false, 0);
    let storage_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let clear_cache = gtk::Button::with_label("Limpar cache (mantém logins)");
    {
        let app = app.clone();
        let label = usage_label.clone();
        clear_cache.connect_clicked(move |b| {
            b.set_sensitive(false);
            let (app2, label, b) = (app.clone(), label.clone(), b.clone());
            webdata::clear_cache(&app, move |r| {
                b.set_sensitive(true);
                match r {
                    Ok(()) => refresh_usage(&app2, &label),
                    Err(e) => message("Não consegui limpar o cache", &e, gtk::MessageType::Error),
                }
            });
        });
    }
    let by_site = gtk::Button::with_label("Gerenciar por site…");
    {
        let app = app.clone();
        by_site.connect_clicked(move |_| site_manager(&app));
    }
    storage_row.pack_start(&clear_cache, false, false, 0);
    storage_row.pack_start(&by_site, false, false, 0);
    col.pack_start(&storage_row, false, false, 0);

    // ── backup ──
    col.pack_start(&section("Backup / migração do Mac"), false, false, 0);
    let backup_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let imp = gtk::Button::with_label("Importar backup do Mac…");
    {
        let app = app.clone();
        imp.connect_clicked(move |_| import_backup(&app));
    }
    let exp = gtk::Button::with_label("Exportar backup…");
    {
        let app = app.clone();
        exp.connect_clicked(move |_| export_backup(&app));
    }
    backup_row.pack_start(&imp, false, false, 0);
    backup_row.pack_start(&exp, false, false, 0);
    col.pack_start(&backup_row, false, false, 0);
    let note2 = gtk::Label::new(Some("Logins, cookies e sessões (ex.: QR do WhatsApp) não migram: entre de novo em cada site."));
    note2.set_xalign(0.0);
    note2.set_line_wrap(true);
    note2.style_context().add_class("dim-label");
    col.pack_start(&note2, false, false, 0);

    // ── créditos ──
    col.pack_start(&section("Sobre"), false, false, 0);
    let about = gtk::Label::new(Some(&format!(
        "EasyBar para Linux {}\nFeito em vibe coding (Felipe Durante e Claude) e revisado por Felipe Durante.",
        env!("CARGO_PKG_VERSION")
    )));
    about.set_xalign(0.0);
    col.pack_start(&about, false, false, 0);

    let app = app.clone();
    d.connect_response(move |d, resp| {
        if resp != gtk::ResponseType::Accept {
            d.close();
            return;
        }
        let hk_text = hotkey.text().trim().to_string();
        if Hotkey::parse(&hk_text).is_none() {
            hotkey_msg.set_markup("<span foreground=\"#d33\">Atalho inválido. Use algo como Alt+Q (com ao menos um modificador).</span>");
            return;
        }
        {
            let mut st = app.settings.borrow_mut();
            if let Some(i) = direction.active() {
                st.direction = Direction::ALL[i as usize];
            }
            st.width_percent = width.value() / 100.0;
            st.height_percent = height.value() / 100.0;
            st.vertical_offset_percent = offset.value() / 100.0;
            st.hotkey = hk_text;
            st.launch_at_login = autostart.is_active();
            st.ask_download_location = ask.is_active();
            st.download_dir = dir_btn
                .filename()
                .map(|p| p.to_string_lossy().into_owned())
                .filter(|p| std::path::Path::new(p) != app.paths.default_downloads);
            st.auto_suspend_enabled = suspend.is_active();
            if let Some(i) = minutes.active() {
                st.auto_suspend_minutes = model::AUTO_SUSPEND_CHOICES[i as usize];
            }
            let ua_text = ua.text().trim().to_string();
            st.user_agent = (!ua_text.is_empty()).then_some(ua_text);
            st.sanitize();
        }
        app.save_settings();
        app.reapply_geometry();
        app.apply_hotkey();
        crate::system::sync_autostart(&app.settings.borrow().launch_at_login);
        crate::tabs::apply_user_agent_to_all(&app);
        d.close();
    });
    d.show_all();
}

fn refresh_usage(app: &Rc<App>, label: &gtk::Label) {
    let label = label.clone();
    webdata::usage_async(app, move |u| {
        label.set_text(&format!(
            "Dados dos sites (logins etc.): {}   ·   Cache: {}",
            human_size(u.data),
            human_size(u.cache)
        ));
    });
}

// ───────────────────────── armazenamento por site ─────────────────────────

fn site_manager(app: &Rc<App>) {
    let d = base_dialog("Armazenamento por site");
    d.set_default_size(560, 480);
    d.add_button("Fechar", gtk::ResponseType::Close);
    d.connect_response(|d, _| d.close());

    let scroll = gtk::ScrolledWindow::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
    let list = gtk::ListBox::new();
    list.set_selection_mode(gtk::SelectionMode::None);
    scroll.add(&list);
    d.content_area().pack_start(&scroll, true, true, 0);

    let loading = gtk::Label::new(Some("Carregando…"));
    list.add(&loading);

    let bottom = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    bottom.set_border_width(10);
    let wipe = gtk::Button::with_label("Apagar TUDO (inclui logins)…");
    {
        let app = app.clone();
        wipe.connect_clicked(move |_| {
            let c = gtk::MessageDialog::new(
                None::<&gtk::Window>,
                gtk::DialogFlags::empty(),
                gtk::MessageType::Warning,
                gtk::ButtonsType::None,
                "Apagar todos os dados de navegação?",
            );
            c.set_keep_above(true);
            c.set_secondary_text(Some("Você sairá de todos os sites (logins, cookies, armazenamento local). Isso não pode ser desfeito."));
            c.add_button("Cancelar", gtk::ResponseType::Cancel);
            c.add_button("Apagar tudo", gtk::ResponseType::Accept);
            let app = app.clone();
            c.connect_response(move |c, r| {
                if r == gtk::ResponseType::Accept {
                    webdata::clear_everything(&app, |res| {
                        if let Err(e) = res {
                            message("Falha ao apagar", &e, gtk::MessageType::Error);
                        }
                    });
                }
                c.close();
            });
            c.show();
        });
    }
    bottom.pack_end(&wipe, false, false, 0);
    d.content_area().pack_start(&bottom, false, false, 0);

    let app2 = app.clone();
    webdata::fetch_sites(app, move |result| {
        list.remove(&loading);
        match result {
            Err(e) => {
                list.add(&gtk::Label::new(Some(&format!("Erro: {e}"))));
            }
            Ok(sites) => {
                if sites.is_empty() {
                    list.add(&gtk::Label::new(Some("Nenhum site com dados guardados.")));
                }
                for site in sites {
                    let r = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                    r.set_border_width(6);
                    let info = gtk::Box::new(gtk::Orientation::Vertical, 2);
                    let name = gtk::Label::new(Some(&site.name));
                    name.set_xalign(0.0);
                    name.set_ellipsize(gtk::pango::EllipsizeMode::End);
                    let sizes = gtk::Label::new(Some(&format!(
                        "Total {}  ·  cache {}",
                        human_size(site.total_size),
                        human_size(site.cache_size)
                    )));
                    sizes.set_xalign(0.0);
                    sizes.style_context().add_class("dim-label");
                    info.pack_start(&name, false, false, 0);
                    info.pack_start(&sizes, false, false, 0);
                    r.pack_start(&info, true, true, 0);
                    let site = Rc::new(site);
                    let cache_btn = gtk::Button::with_label("Limpar cache");
                    let data_btn = gtk::Button::with_label("Apagar dados");
                    for (btn, types) in [
                        (&cache_btn, webdata::cache_types()),
                        (&data_btn, webkit2gtk::WebsiteDataTypes::ALL),
                    ] {
                        let (app, site, btn2) = (app2.clone(), site.clone(), btn.clone());
                        btn.connect_clicked(move |_| {
                            btn2.set_sensitive(false);
                            let btn3 = btn2.clone();
                            webdata::clear_site(&app, &site, types, move |res| {
                                btn3.set_label(if res.is_ok() { "Feito" } else { "Falhou" });
                            });
                        });
                    }
                    r.pack_end(&data_btn, false, false, 0);
                    r.pack_end(&cache_btn, false, false, 0);
                    list.add(&r);
                }
            }
        }
        list.show_all();
    });
    d.show_all();
}
