//! WebViews das abas: criação preguiçosa, política de navegação, falhas de carga,
//! descarregamento automático, permissões e menu de contexto da aba.

use crate::app::App;
use easybar_core::policy::{self, SweepDecision, SweepInput};
use easybar_core::{failure, urls};
use gtk::glib;
use gtk::prelude::*;
use std::rc::Rc;
use std::time::{Duration, Instant};
use webkit2gtk::{
    LoadEvent, NavigationPolicyDecision, NavigationPolicyDecisionExt, NotificationExt, PermissionRequestExt,
    PolicyDecisionExt, PolicyDecisionType, ResponsePolicyDecision, ResponsePolicyDecisionExt, SettingsExt,
    URIRequestExt, URIResponseExt, UserMediaPermissionRequest, UserMediaPermissionRequestExt, WebContextExt,
    WebView, WebViewExt,
};

pub fn start_background_services(app: &Rc<App>) {
    app.web_context.set_cache_model(webkit2gtk::CacheModel::WebBrowser);
    load_permissions(app);
    crate::downloads::connect(app);

    // Varredura de abas inativas a cada 30 s.
    let weak = Rc::downgrade(app);
    glib::timeout_add_seconds_local(30, move || {
        match weak.upgrade() {
            Some(app) => {
                sweep(&app);
                glib::ControlFlow::Continue
            }
            None => glib::ControlFlow::Break,
        }
    });

    // Primeira execução: sem abas → oferece importar o backup do Mac.
    if app.settings.borrow().tabs.is_empty() {
        let app = app.clone();
        glib::idle_add_local_once(move || crate::dialogs::welcome(&app));
    }
}

// ───────────────────────── criação ─────────────────────────

pub fn ensure_view(app: &Rc<App>, id: &str) -> WebView {
    if let Some(v) = app.views.borrow().get(id) {
        return v.clone();
    }
    let tab = app.settings.borrow().tab(id).cloned().expect("aba inexistente");
    let view = new_web_view(app, id, None);
    view.set_hexpand(true);
    view.set_vexpand(true);
    app.stack.add_named(&view, id);
    view.show();
    app.views.borrow_mut().insert(id.to_string(), view.clone());
    app.unloaded.borrow_mut().remove(id);
    app.touch(id);
    app.update_tab_styles();
    match urls::normalize_tab_url(&tab.url) {
        Some(url) => view.load_uri(&url),
        None => app.notify("EasyBar", &format!("Endereço inválido na aba \"{}\": {}", tab.title, tab.url)),
    }
    view
}

/// `related`: popups precisam compartilhar o processo do WebView que os abriu.
fn new_web_view(app: &Rc<App>, id: &str, related: Option<&WebView>) -> WebView {
    let mut builder = WebView::builder().web_context(&app.web_context);
    if let Some(r) = related {
        builder = builder.related_view(r);
    }
    let view = builder.build();
    configure(app, &view);
    connect_signals(app, &view, id);
    view
}

pub fn configure(app: &App, view: &WebView) {
    if let Some(s) = WebViewExt::settings(view) {
        s.set_javascript_can_access_clipboard(true);
        s.set_enable_media_stream(true);
        s.set_enable_mediasource(true);
        s.set_enable_back_forward_navigation_gestures(true);
        if let Some(ua) = app.settings.borrow().user_agent.as_deref().filter(|u| !u.trim().is_empty()) {
            s.set_user_agent(Some(ua));
        }
    }
}

/// Reaplica o User-Agent a todas as abas abertas (depois de mudar nas configurações).
pub fn apply_user_agent_to_all(app: &App) {
    let ua = app.settings.borrow().user_agent.clone().filter(|u| !u.trim().is_empty());
    for view in app.views.borrow().values() {
        if let Some(s) = WebViewExt::settings(view) {
            s.set_user_agent(ua.as_deref());
        }
    }
}

// ───────────────────────── sinais ─────────────────────────

fn host_of(uri: &str) -> String {
    let rest = uri.split_once("://").map_or(uri, |(_, r)| r);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let authority = authority.rsplit('@').next().unwrap_or("");
    authority.split(':').next().unwrap_or("").to_ascii_lowercase()
}

fn scheme_of(uri: &str) -> String {
    uri.split_once(':').map(|(s, _)| s.to_ascii_lowercase()).unwrap_or_default()
}

fn tab_domain(app: &App, id: &str) -> String {
    app.settings
        .borrow()
        .tab(id)
        .map(|t| urls::registrable_domain(&host_of(&t.url)))
        .unwrap_or_default()
}

fn is_different_domain(app: &App, id: &str, uri: &str) -> bool {
    let a = urls::registrable_domain(&host_of(uri));
    let b = tab_domain(app, id);
    !a.is_empty() && !b.is_empty() && a != b
}

fn connect_signals(app: &Rc<App>, view: &WebView, id: &str) {
    // ── carga ──
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_load_changed(move |view, event| match event {
            LoadEvent::Committed => {
                app.pending_cross.borrow_mut().clear();
                // O primeiro "commit" depois de uma falha é a própria página de erro.
                if !app.showing_failure.borrow_mut().remove(&id) {
                    app.failed.borrow_mut().remove(&id);
                }
            }
            LoadEvent::Finished => capture_favicon(&app, view, &id),
            _ => {}
        });
    }
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_favicon_notify(move |view| capture_favicon(&app, view, &id));
    }
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_load_failed(move |view, _event, uri, error| {
            let code = unsafe {
                use glib::translate::ToGlibPtr;
                (*ToGlibPtr::<*const glib::ffi::GError>::to_glib_none(error).0).code
            };
            let domain = error.domain().as_str().to_string();
            if failure::is_ignorable(&domain, code) {
                return false;
            }
            show_failure(&app, view, &id, uri, error.message());
            true
        });
    }
    {
        let app = app.clone();
        view.connect_load_failed_with_tls_errors(move |view, uri, cert, _errors| {
            let host = host_of(uri);
            if urls::is_local_network_address(&host) {
                // Dispositivos locais (roteador, NAS) costumam ter certificado autoassinado.
                app.web_context.allow_tls_certificate_for_host(cert, &host);
                view.load_uri(uri);
                return true;
            }
            false // cai em load-failed → página de erro de SSL
        });
    }
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_web_process_terminated(move |view, _reason| {
            let now = Instant::now();
            let recent = {
                let mut map = app.terminations.borrow_mut();
                let list = map.entry(id.clone()).or_default();
                list.retain(|t| now.duration_since(*t) < Duration::from_secs(120));
                list.push(now);
                list.len()
            };
            if recent > 3 {
                let uri = view.uri().map(|u| u.to_string()).unwrap_or_default();
                show_failure(&app, view, &id, &uri, "O processo da página travou várias vezes seguidas.");
                return;
            }
            let v = view.clone();
            glib::timeout_add_local_once(Duration::from_millis(500), move || v.reload());
        });
    }

    // ── política de navegação / downloads ──
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_decide_policy(move |view, decision, ty| decide_policy(&app, view, &id, decision, ty));
    }

    // ── popups ──
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_create(move |view, action| create_popup(&app, view, &id, action));
    }

    // ── permissões (microfone, câmera, notificações, localização) ──
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_permission_request(move |view, request| {
            handle_permission(&app, view, &id, request);
            true
        });
    }
    // ── notificações da página → notificações do sistema ──
    {
        let app = app.clone();
        let id = id.to_string();
        view.connect_show_notification(move |_, n| {
            let notification = gio::Notification::new(&n.title().map(|t| t.to_string()).unwrap_or_default());
            notification.set_body(n.body().as_deref());
            notification.set_default_action("app.show");
            app.gtk_app
                .send_notification(Some(&format!("web-{id}-{}", n.id())), &notification);
            true
        });
    }
    // Tela cheia dentro de um painel deslizante tomaria o monitor inteiro → nega.
    view.connect_enter_fullscreen(|_| true);
    // window.close() de scripts: ignora.
    view.connect_close(|_| {});
}

fn show_failure(app: &Rc<App>, view: &WebView, id: &str, uri: &str, message: &str) {
    let info = failure::describe(message);
    if info.connectivity {
        app.failed.borrow_mut().insert(id.to_string(), uri.to_string());
    }
    let title = app.settings.borrow().tab(id).map(|t| t.title.clone()).unwrap_or_default();
    let html = failure::page_html(uri, &host_of(uri), &title, &info, message);
    app.showing_failure.borrow_mut().insert(id.to_string());
    view.load_alternate_html(&html, uri, Some(uri));
}

// ───────────────────────── favicon ─────────────────────────

fn capture_favicon(app: &Rc<App>, view: &WebView, id: &str) {
    let missing = app.settings.borrow().tab(id).map_or(false, |t| t.favicon.is_none());
    if !missing {
        return;
    }
    let Some(surface) = view.favicon() else { return };
    let Ok(img) = gtk::cairo::ImageSurface::try_from(surface) else { return };
    if img.width() < 8 || img.height() < 8 {
        return;
    }
    let mut png = Vec::new();
    if img.write_to_png(&mut png).is_err() {
        return;
    }
    let b64 = glib::base64_encode(&png).to_string();
    if let Some(t) = app.settings.borrow_mut().tab_mut(id) {
        t.favicon = Some(b64);
    }
    app.save_settings();
    app.rebuild_tab_bar();
}

// ───────────────────────── política ─────────────────────────

fn decide_policy(app: &Rc<App>, view: &WebView, id: &str, decision: &webkit2gtk::PolicyDecision, ty: PolicyDecisionType) -> bool {
    match ty {
        PolicyDecisionType::NavigationAction => {
            let Some(nav) = decision.downcast_ref::<NavigationPolicyDecision>() else { return false };
            let Some(action) = nav.navigation_action() else { return false };
            let Some(uri) = action.request().and_then(|r| r.uri()).map(|u| u.to_string()) else { return false };
            let scheme = scheme_of(&uri);

            match scheme.as_str() {
                "http" | "https" | "about" | "blob" | "data" | "file" | "" => {}
                s if urls::external_scheme_allowed(s) => {
                    // mailto: abre fora; a navegação interna é cancelada.
                    decision.ignore();
                    open_external(&uri);
                    return true;
                }
                _ => {
                    // smb://, vnc://, x-…: nunca deixa o conteúdo web acionar outros programas.
                    decision.ignore();
                    return true;
                }
            }

            if action.navigation_type() == webkit2gtk::NavigationType::LinkClicked
                && matches!(scheme.as_str(), "http" | "https")
                && !urls::is_auth_domain(&host_of(&uri))
                && is_different_domain(app, id, &uri)
            {
                // Pode ser página externa OU download em CDN: decide quando a resposta chegar.
                app.pending_cross.borrow_mut().insert(uri);
            }
            false
        }
        PolicyDecisionType::Response => {
            let Some(resp_decision) = decision.downcast_ref::<ResponsePolicyDecision>() else { return false };
            let Some(response) = resp_decision.response() else { return false };
            let resp_uri = response.uri().map(|u| u.to_string()).unwrap_or_default();

            let attachment = response
                .http_headers()
                .and_then(|h| h.one("Content-Disposition"))
                .map_or(false, |v| v.to_ascii_lowercase().contains("attachment"));
            if attachment || !resp_decision.is_mime_type_supported() {
                app.pending_cross.borrow_mut().remove(&resp_uri);
                decision.download();
                return true;
            }

            // Página renderizável de outro domínio, aberta por clique do usuário → pergunta.
            let main_uri = view.uri().map(|u| u.to_string()).unwrap_or_default();
            let _ = main_uri;
            if app.pending_cross.borrow_mut().remove(&resp_uri) {
                decision.ignore();
                let app = app.clone();
                let view = view.clone();
                glib::idle_add_local_once(move || ask_external_link(&app, &view, &resp_uri));
                return true;
            }
            false
        }
        _ => false, // NewWindowAction: tratado em `create`
    }
}

pub fn open_external(uri: &str) {
    if !urls::external_scheme_allowed(&scheme_of(uri)) {
        eprintln!("[EasyBar] Recusado abrir URL de esquema não permitido: {}", scheme_of(uri));
        return;
    }
    let _ = gio::AppInfo::launch_default_for_uri(uri, gio::AppLaunchContext::NONE);
}

fn ask_external_link(app: &Rc<App>, view: &WebView, uri: &str) {
    let dialog = gtk::MessageDialog::new(
        None::<&gtk::Window>,
        gtk::DialogFlags::empty(),
        gtk::MessageType::Question,
        gtk::ButtonsType::None,
        &format!("Abrir link de {}?", host_of(uri)),
    );
    dialog.set_keep_above(true);
    dialog.set_secondary_text(Some(uri));
    dialog.add_button("Cancelar", gtk::ResponseType::Cancel);
    dialog.add_button("Nesta aba", gtk::ResponseType::No);
    dialog.add_button("Navegador padrão", gtk::ResponseType::Yes);
    let view = view.clone();
    let uri = uri.to_string();
    let _ = app;
    dialog.connect_response(move |d, r| {
        match r {
            gtk::ResponseType::Yes => open_external(&uri),
            gtk::ResponseType::No => view.load_uri(&uri), // programático: não gera nova pergunta
            _ => {}
        }
        d.close();
    });
    dialog.show();
}

fn create_popup(app: &Rc<App>, view: &WebView, id: &str, action: &webkit2gtk::NavigationAction) -> Option<gtk::Widget> {
    let uri = action.request().and_then(|r| r.uri()).map(|u| u.to_string()).unwrap_or_default();
    let scheme = scheme_of(&uri);
    let host = host_of(&uri);
    let is_auth = !host.is_empty() && urls::is_auth_domain(&host);

    // Popup que é (ou vai virar) download: window.open() + <a download>/blob:.
    let webish = scheme.is_empty() || matches!(scheme.as_str(), "http" | "https" | "blob" | "data" | "about");
    let looks_like_download = webish && (uri.is_empty() || host.is_empty() || scheme == "blob" || scheme == "data");
    if looks_like_download && !is_auth {
        let popup = new_web_view(app, id, Some(view));
        let holder = gtk::OffscreenWindow::new();
        holder.add(&popup);
        holder.show_all();
        glib::timeout_add_seconds_local_once(180, move || unsafe { holder.destroy() });
        return Some(popup.upcast());
    }

    if is_auth {
        let popup = new_web_view(app, id, Some(view));
        let win = gtk::Window::new(gtk::WindowType::Toplevel);
        win.set_title("Autenticação");
        win.set_default_size(520, 660);
        win.set_keep_above(true);
        win.set_position(gtk::WindowPosition::Center);
        win.add(&popup);
        {
            let win = win.clone();
            popup.connect_close(move |_| win.close());
        }
        {
            // OAuth que volta ao domínio da aba: recarrega a aba principal e fecha o popup.
            let app = app.clone();
            let id = id.to_string();
            let parent = view.clone();
            let win = win.clone();
            popup.connect_load_changed(move |v, ev| {
                if ev != LoadEvent::Committed {
                    return;
                }
                let uri = v.uri().map(|u| u.to_string()).unwrap_or_default();
                let back = !is_different_domain(&app, &id, &uri) && !host_of(&uri).is_empty();
                if back {
                    parent.reload();
                    win.close();
                }
            });
        }
        win.show_all();
        return Some(popup.upcast());
    }

    // Qualquer outro popup (target=_blank): abre no navegador padrão.
    if !uri.is_empty() {
        open_external(&uri);
    }
    None
}

// ───────────────────────── permissões ─────────────────────────

fn permissions_file(app: &App) -> std::path::PathBuf {
    app.paths.settings_file.with_file_name("permissions.json")
}

fn load_permissions(app: &App) {
    if let Ok(text) = std::fs::read_to_string(permissions_file(app)) {
        if let Ok(map) = serde_json::from_str::<std::collections::HashMap<String, bool>>(&text) {
            *app.permission_cache.borrow_mut() = map;
        }
    }
}

fn save_permissions(app: &App) {
    if let Ok(text) = serde_json::to_string_pretty(&*app.permission_cache.borrow()) {
        let _ = std::fs::write(permissions_file(app), text);
    }
}

fn handle_permission(app: &Rc<App>, view: &WebView, _id: &str, request: &webkit2gtk::PermissionRequest) {
    let host = view.uri().map(|u| host_of(u.as_str())).unwrap_or_default();
    let (kind, label) = if let Some(m) = request.downcast_ref::<UserMediaPermissionRequest>() {
        match (m.is_for_audio_device(), m.is_for_video_device()) {
            (true, true) => ("media-av", "usar o microfone e a câmera"),
            (true, false) => ("media-audio", "usar o microfone"),
            _ => ("media-video", "usar a câmera"),
        }
    } else if request.is::<webkit2gtk::NotificationPermissionRequest>() {
        ("notifications", "mostrar notificações")
    } else if request.is::<webkit2gtk::GeolocationPermissionRequest>() {
        ("geolocation", "saber sua localização")
    } else {
        request.deny();
        return;
    };
    let key = format!("{host}|{kind}");
    if let Some(&allowed) = app.permission_cache.borrow().get(&key) {
        if allowed { request.allow() } else { request.deny() }
        return;
    }
    let dialog = gtk::MessageDialog::new(
        None::<&gtk::Window>,
        gtk::DialogFlags::empty(),
        gtk::MessageType::Question,
        gtk::ButtonsType::None,
        &format!("{host} quer {label}."),
    );
    dialog.set_keep_above(true);
    dialog.add_button("Bloquear", gtk::ResponseType::No);
    dialog.add_button("Permitir", gtk::ResponseType::Yes);
    let app = app.clone();
    let request = request.clone();
    dialog.connect_response(move |d, r| {
        let allowed = r == gtk::ResponseType::Yes;
        if r == gtk::ResponseType::Yes || r == gtk::ResponseType::No {
            app.permission_cache.borrow_mut().insert(key.clone(), allowed);
            save_permissions(&app);
        }
        if allowed { request.allow() } else { request.deny() }
        d.close();
    });
    dialog.show();
}

// ───────────────────────── descarregar / recarregar / remover ─────────────────────────

/// Destrói o WebView da aba (libera a memória do processo web). A aba continua na barra.
pub fn suspend_tab(app: &Rc<App>, id: &str) {
    let Some(view) = app.views.borrow_mut().remove(id) else { return };
    app.stack.remove(&view);
    // Se dropar não destruir (referência extra), força o fim do processo.
    view.try_close();
    drop(view);
    app.unloaded.borrow_mut().insert(id.to_string());
    app.failed.borrow_mut().remove(id);
    app.update_tab_styles();
}

pub fn reload_tab(app: &Rc<App>, id: &str) {
    let existing = app.views.borrow().get(id).cloned();
    match existing {
        Some(v) => v.reload(),
        None => {
            ensure_view(app, id);
        }
    }
}

pub fn remove_tab(app: &Rc<App>, id: &str) {
    suspend_tab(app, id);
    app.unloaded.borrow_mut().remove(id);
    app.last_active.borrow_mut().remove(id);
    {
        let mut s = app.settings.borrow_mut();
        s.tabs.retain(|t| t.id != id);
        if s.selected_tab.as_deref() == Some(id) {
            s.selected_tab = s.tabs.first().map(|t| t.id.clone());
        }
    }
    app.rebuild_tab_bar();
    if let Some(next) = app.selected_id() {
        app.select_tab(&next, false);
    }
    app.save_settings();
}

/// Reconstrói tudo a partir de novas configurações (importação de backup).
pub fn replace_all(app: &Rc<App>, new_settings: easybar_core::model::Settings) {
    let ids: Vec<String> = app.views.borrow().keys().cloned().collect();
    for id in ids {
        suspend_tab(app, &id);
    }
    app.unloaded.borrow_mut().clear();
    app.failed.borrow_mut().clear();
    *app.settings.borrow_mut() = new_settings;
    app.settings.borrow_mut().sanitize();
    app.rebuild_tab_bar();
    if let Some(id) = app.selected_id() {
        app.select_tab(&id, false);
    }
    app.reapply_geometry();
    app.apply_hotkey();
    crate::system::sync_autostart(&app.settings.borrow().launch_at_login);
    apply_user_agent_to_all(app);
    app.save_settings();
}

// ───────────────────────── varredura / rede ─────────────────────────

fn sweep(app: &Rc<App>) {
    let selected = app.selected_id();
    let visible = app.visible.get();
    let downloading = app.downloads.borrow().active > 0;
    let ids: Vec<String> = app.views.borrow().keys().cloned().collect();
    for id in ids {
        let (minutes, view) = {
            let s = app.settings.borrow();
            let Some(tab) = s.tab(&id) else { continue };
            (policy::effective_auto_suspend_minutes(&s, tab), app.views.borrow().get(&id).cloned())
        };
        let Some(view) = view else { continue };
        let idle = app
            .last_active
            .borrow()
            .get(&id)
            .map_or(Duration::ZERO, |t| t.elapsed());
        let input = SweepInput {
            idle,
            minutes,
            is_front: visible && selected.as_deref() == Some(id.as_str()),
            protected: view.is_playing_audio(),
            downloading,
        };
        match policy::decide(&input) {
            SweepDecision::Keep => {}
            SweepDecision::Touch => app.touch(&id),
            SweepDecision::Suspend => suspend_tab(app, &id),
        }
    }
}

/// Rede voltou / PC acordou: recarrega as abas que tinham falhado por conexão.
pub fn retry_failed(app: &Rc<App>) {
    let ids: Vec<String> = app.failed.borrow().keys().cloned().collect();
    for id in ids {
        app.failed.borrow_mut().remove(&id);
        let view = app.views.borrow().get(&id).cloned();
        if let Some(view) = view {
            view.reload();
        }
    }
}

// ───────────────────────── menu da aba (botão direito) ─────────────────────────

pub fn show_tab_menu(app: &Rc<App>, id: &str, _ev: &gtk::gdk::EventButton) {
    let menu = gtk::Menu::new();
    let loaded = app.views.borrow().contains_key(id);

    let item = |label: &str| gtk::MenuItem::with_label(label);

    let reload = item(if loaded { "Recarregar" } else { "Carregar" });
    {
        let (app, id) = (app.clone(), id.to_string());
        reload.connect_activate(move |_| reload_tab(&app, &id));
    }
    menu.append(&reload);

    if loaded {
        let unload = item("Descarregar agora");
        let (app2, id2) = (app.clone(), id.to_string());
        unload.connect_activate(move |_| {
            suspend_tab(&app2, &id2);
            if app2.selected_id().as_deref() == Some(id2.as_str()) && app2.visible.get() {
                // aba aberta descarregada: volta sozinha ao reselecionar
            }
        });
        menu.append(&unload);
    }

    // Descarregamento automático desta aba
    let current = app.settings.borrow().tab(id).and_then(|t| t.auto_suspend_minutes);
    let sub = gtk::Menu::new();
    let mut group: Option<gtk::RadioMenuItem> = None;
    let mut options: Vec<(String, Option<u32>)> = vec![
        ("Padrão (configuração geral)".to_string(), None),
        ("Nunca descarregar".to_string(), Some(0)),
    ];
    for m in easybar_core::model::AUTO_SUSPEND_CHOICES {
        options.push((format!("Após {}", easybar_core::model::auto_suspend_label(m)), Some(m)));
    }
    for (label, value) in options {
        let radio = match &group {
            Some(g) => gtk::RadioMenuItem::with_label_from_widget(g, Some(&label)),
            None => gtk::RadioMenuItem::with_label(&label),
        };
        if group.is_none() {
            group = Some(radio.clone());
        }
        radio.set_active(value == current);
        let (app2, id2) = (app.clone(), id.to_string());
        radio.connect_toggled(move |r| {
            if r.is_active() {
                if let Some(t) = app2.settings.borrow_mut().tab_mut(&id2) {
                    t.auto_suspend_minutes = value;
                }
                app2.save_settings();
            }
        });
        sub.append(&radio);
    }
    let auto = item("Descarregar automaticamente");
    auto.set_submenu(Some(&sub));
    menu.append(&auto);

    menu.append(&gtk::SeparatorMenuItem::new());

    let edit = item("Editar…");
    {
        let (app, id) = (app.clone(), id.to_string());
        edit.connect_activate(move |_| crate::dialogs::edit_tab(&app, &id));
    }
    menu.append(&edit);

    let remove = item("Remover aba");
    {
        let (app, id) = (app.clone(), id.to_string());
        remove.connect_activate(move |_| crate::dialogs::confirm_remove_tab(&app, &id));
    }
    menu.append(&remove);

    menu.show_all();
    menu.popup_at_pointer(None);
}
