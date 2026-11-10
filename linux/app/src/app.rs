//! Estado central do app, janela do painel, barra de abas e o deslizar.

use crate::config::Paths;
use crate::downloads::DownloadsState;
use crate::style;
use easybar_core::geometry::{self, Rect};
use easybar_core::hotkey::Hotkey;
use easybar_core::model::{Direction, Settings, Tab};
use gtk::prelude::*;
use gtk::{gdk, glib};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Instant;
use webkit2gtk::{WebContext, WebView, WebsiteDataManager, WebsiteDataManagerExt};

pub const APP_ID: &str = "br.com.easybar.EasyBar";

/// Igual a `dbg`, mas pode ser chamado de outras threads.
pub fn dbg_thread(msg: impl AsRef<str>) {
    dbg(msg)
}

/// Registro de diagnóstico no terminal: `[EasyBar +1234ms] mensagem`.
pub fn dbg(msg: impl AsRef<str>) {
    use std::sync::OnceLock;
    static START: OnceLock<Instant> = OnceLock::new();
    let t = START.get_or_init(Instant::now).elapsed().as_millis();
    eprintln!("[EasyBar +{t}ms] {}", msg.as_ref());
}

pub struct App {
    pub gtk_app: gtk::Application,
    pub paths: Paths,
    pub settings: RefCell<Settings>,

    // ── interface ──
    pub window: gtk::Window,
    pub stack: gtk::Stack,
    /// Conteúdo do painel em tamanho CHEIO (nunca é redimensionado durante o deslize).
    pub root: gtk::Box,
    /// Janela de rolagem "externa": mostra só uma fatia do `root` (o deslize recortado).
    pub scroller: gtk::ScrolledWindow,
    pub tab_box: gtk::Box,
    pub hide_icon: gtk::Image,
    pub tab_buttons: RefCell<HashMap<String, gtk::Button>>,

    // ── web ──
    pub web_context: WebContext,
    pub data_manager: WebsiteDataManager,
    pub views: RefCell<HashMap<String, WebView>>,
    pub last_active: RefCell<HashMap<String, Instant>>,
    /// Abas cujo WebView foi descarregado (a aba continua na barra, esmaecida).
    pub unloaded: RefCell<HashSet<String>>,
    /// Abas cuja última navegação falhou por conexão → recarregam sozinhas quando a rede volta.
    pub failed: RefCell<HashMap<String, String>>,
    pub terminations: RefCell<HashMap<String, Vec<Instant>>>,
    /// URLs de links para OUTRO domínio aguardando a resposta HTTP (ver `tabs.rs`).
    pub pending_cross: RefCell<HashSet<String>>,
    /// Abas que estão carregando a PRÓPRIA página de erro (não contam como sucesso).
    pub showing_failure: RefCell<HashSet<String>>,
    pub permission_cache: RefCell<HashMap<String, bool>>,
    pub downloads: RefCell<DownloadsState>,

    // ── painel ──
    pub visible: Cell<bool>,
    pub last_full: Cell<Option<Rect>>,
    slide_source: RefCell<Option<gtk::TickCallbackId>>,
    /// Último retângulo (x, y, largura, altura) enviado à janela — evita pedidos repetidos ao X.
    applied: Cell<Option<(i32, i32, i32, i32)>>,

    pub hotkey_service: RefCell<Option<crate::hotkey::HotkeyService>>,
}

impl App {
    pub fn new(gtk_app: &gtk::Application) -> Rc<App> {
        let paths = Paths::new();

        // Configurações: arquivo corrompido não pode impedir o app de abrir.
        let mut load_warning = None;
        let settings = match Settings::load(&paths.settings_file) {
            Ok(s) => s,
            Err(e) => {
                let bad = paths.settings_file.with_extension("json.corrompido");
                let _ = std::fs::rename(&paths.settings_file, &bad);
                load_warning = Some(format!(
                    "Não consegui ler as configurações ({e}). Usei os padrões; o arquivo antigo foi guardado em {}.",
                    bad.display()
                ));
                Settings::default()
            }
        };

        let _ = std::fs::create_dir_all(&paths.web_data);
        let _ = std::fs::create_dir_all(&paths.web_cache);
        let data_manager = WebsiteDataManager::builder()
            .base_data_directory(paths.web_data.to_string_lossy().as_ref())
            .base_cache_directory(paths.web_cache.to_string_lossy().as_ref())
            .build();
        if let Some(cookies) = data_manager.cookie_manager() {
            use webkit2gtk::CookieManagerExt;
            cookies.set_persistent_storage(
                paths.cookies_db.to_string_lossy().as_ref(),
                webkit2gtk::CookiePersistentStorage::Sqlite,
            );
        }
        let web_context = WebContext::with_website_data_manager(&data_manager);

        // ── janela do painel ──
        let window = gtk::Window::new(gtk::WindowType::Toplevel);
        window.set_title("EasyBar");
        window.set_role("easybar-panel");
        window.set_decorated(false);
        window.set_skip_taskbar_hint(true);
        window.set_skip_pager_hint(true);
        window.set_keep_above(true);
        // Sem decoração não há alças de redimensionar; `resizable` precisa ficar ligado
        // para o `resize()` do deslize funcionar.
        window.set_resizable(true);
        window.set_accept_focus(true);
        window.stick();
        window.style_context().add_class("easybar");

        let stack = gtk::Stack::new();
        stack.set_hexpand(true);
        stack.set_vexpand(true);
        stack.set_transition_type(gtk::StackTransitionType::None);

        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let scroller = gtk::ScrolledWindow::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
        // EXTERNAL = sem barras e, principalmente, o tamanho mínimo do conteúdo NÃO
        // vira o tamanho mínimo da janela → a janela pode encolher até a fatia visível.
        scroller.set_policy(gtk::PolicyType::External, gtk::PolicyType::External);
        scroller.set_shadow_type(gtk::ShadowType::None);
        scroller.set_kinetic_scrolling(false);
        // A rolagem aqui é só do deslize; o mouse não pode mexer nela.
        scroller.connect_scroll_event(|_, _| glib::Propagation::Stop);
        let tab_box = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        let hide_icon = gtk::Image::from_icon_name(Some(hide_icon_name(settings.direction)), gtk::IconSize::Button);

        let app = Rc::new(App {
            gtk_app: gtk_app.clone(),
            paths,
            settings: RefCell::new(settings),
            window,
            stack,
            root,
            scroller,
            tab_box,
            hide_icon,
            tab_buttons: RefCell::new(HashMap::new()),
            web_context,
            data_manager,
            views: RefCell::new(HashMap::new()),
            last_active: RefCell::new(HashMap::new()),
            unloaded: RefCell::new(HashSet::new()),
            failed: RefCell::new(HashMap::new()),
            terminations: RefCell::new(HashMap::new()),
            pending_cross: RefCell::new(HashSet::new()),
            showing_failure: RefCell::new(HashSet::new()),
            permission_cache: RefCell::new(HashMap::new()),
            downloads: RefCell::new(DownloadsState::default()),
            visible: Cell::new(false),
            last_full: Cell::new(None),
            slide_source: RefCell::new(None),
            applied: Cell::new(None),
            hotkey_service: RefCell::new(None),
        });

        style::install();
        app.build_layout();
        app.rebuild_tab_bar();
        // (o empréstimo de `settings` precisa acabar antes de `select_tab`, que grava nele)
        let initial = app.settings.borrow().selected_tab.clone();
        if let Some(id) = initial {
            app.select_tab(&id, false);
        }
        // A janela precisa estar "realizada" para termos o GdkWindow (recorte do deslize).
        app.window.realize();
        // Alt+F4 / fechar pela barra de tarefas: só esconde o painel (não destrói a janela).
        {
            let app2 = app.clone();
            app.window.connect_delete_event(move |_, _| {
                app2.hide_panel();
                glib::Propagation::Stop
            });
        }
        app.window.connect_map_event(|_, _| { dbg("janela: MAPEADA (visível)"); glib::Propagation::Proceed });
        app.window.connect_unmap_event(|_, _| { dbg("janela: DESMAPEADA (sumiu)"); glib::Propagation::Proceed });
        app.window.connect_focus_in_event(|_, _| { dbg("janela: ganhou foco"); glib::Propagation::Proceed });
        app.window.connect_focus_out_event(|_, _| { dbg("janela: perdeu foco"); glib::Propagation::Proceed });
        crate::tabs::start_background_services(&app);
        crate::system::start(&app);
        app.apply_hotkey();

        if let Some(msg) = load_warning {
            app.notify("EasyBar", &msg);
        }
        app
    }

    // ───────────────────────── layout ─────────────────────────

    fn build_layout(self: &Rc<Self>) {
        let root = &self.root;
        root.pack_start(&self.stack, true, true, 0);
        root.pack_start(&gtk::Separator::new(gtk::Orientation::Horizontal), false, false, 0);

        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 2);
        bar.style_context().add_class("tabbar");
        bar.set_size_request(-1, 46);

        // esconder
        let hide_btn = gtk::Button::new();
        hide_btn.set_image(Some(&self.hide_icon));
        hide_btn.set_relief(gtk::ReliefStyle::None);
        hide_btn.set_tooltip_text(Some("Ocultar"));
        {
            let app = self.clone();
            hide_btn.connect_clicked(move |_| app.hide_panel());
        }
        bar.pack_start(&hide_btn, false, false, 2);

        // abas (rolagem horizontal)
        let scroll = gtk::ScrolledWindow::new(None::<&gtk::Adjustment>, None::<&gtk::Adjustment>);
        scroll.set_policy(gtk::PolicyType::Automatic, gtk::PolicyType::Never);
        scroll.set_hexpand(true);
        scroll.add(&self.tab_box);
        bar.pack_start(&scroll, true, true, 0);

        // ações
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        for (icon, tip, action) in [
            ("list-add-symbolic", "Adicionar aba", "add-tab"),
            ("folder-download-symbolic", "Downloads", "downloads"),
            ("emblem-system-symbolic", "Configurações", "settings"),
            ("application-exit-symbolic", "Sair do EasyBar", "quit"),
        ] {
            let b = gtk::Button::from_icon_name(Some(icon), gtk::IconSize::Button);
            b.set_relief(gtk::ReliefStyle::None);
            b.set_tooltip_text(Some(tip));
            let app = self.clone();
            b.connect_clicked(move |_| app.run_action(action));
            actions.pack_start(&b, false, false, 0);
        }
        bar.pack_end(&actions, false, false, 4);

        root.pack_start(&bar, false, false, 0);
        self.scroller.add(root);
        self.scroller.show_all();
        self.window.add(&self.scroller);
    }

    pub fn run_action(self: &Rc<Self>, action: &str) {
        match action {
            "toggle" => self.toggle(),
            "show" => self.show_panel(),
            "hide" => self.hide_panel(),
            "add-tab" => crate::dialogs::add_tab(self),
            "downloads" => crate::downloads::show_window(self),
            "settings" => crate::dialogs::settings(self),
            "quit" => self.gtk_app.quit(),
            other => eprintln!("[EasyBar] ação desconhecida: {other}"),
        }
    }

    // ───────────────────────── barra de abas ─────────────────────────

    pub fn rebuild_tab_bar(self: &Rc<Self>) {
        for child in self.tab_box.children() {
            self.tab_box.remove(&child);
        }
        self.tab_buttons.borrow_mut().clear();
        let tabs: Vec<Tab> = self.settings.borrow().tabs.clone();
        for tab in &tabs {
            let button = self.make_tab_button(tab);
            self.tab_box.pack_start(&button, false, false, 0);
            self.tab_buttons.borrow_mut().insert(tab.id.clone(), button);
        }
        self.tab_box.show_all();
        self.update_tab_styles();
    }

    fn make_tab_button(self: &Rc<Self>, tab: &Tab) -> gtk::Button {
        let button = gtk::Button::new();
        button.set_relief(gtk::ReliefStyle::None);
        button.style_context().add_class("tabbtn");
        button.set_size_request(58, 42);

        let content = gtk::Box::new(gtk::Orientation::Vertical, 1);
        content.pack_start(&tab_icon(tab), false, false, 0);
        let label = gtk::Label::new(Some(&short_title(&tab.title)));
        label.set_max_width_chars(9);
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        content.pack_start(&label, false, false, 0);
        button.add(&content);
        button.set_tooltip_text(Some(&tab.title));

        let id = tab.id.clone();
        {
            let app = self.clone();
            let id = id.clone();
            button.connect_clicked(move |_| app.select_tab(&id, true));
        }
        {
            let app = self.clone();
            let id = id.clone();
            button.connect_button_press_event(move |_, ev| {
                if ev.button() == 3 {
                    crate::tabs::show_tab_menu(&app, &id, ev);
                    return glib::Propagation::Stop;
                }
                glib::Propagation::Proceed
            });
        }
        button
    }

    pub fn update_tab_styles(&self) {
        let selected = self.settings.borrow().selected_tab.clone();
        let unloaded = self.unloaded.borrow();
        for (id, button) in self.tab_buttons.borrow().iter() {
            let ctx = button.style_context();
            for (class, on) in [
                ("selected", selected.as_deref() == Some(id.as_str())),
                ("unloaded", unloaded.contains(id)),
            ] {
                if on { ctx.add_class(class) } else { ctx.remove_class(class) }
            }
        }
    }

    pub fn select_tab(self: &Rc<Self>, id: &str, save: bool) {
        if self.settings.borrow().tab(id).is_none() {
            return;
        }
        self.settings.borrow_mut().selected_tab = Some(id.to_string());
        self.touch(id);
        let view = crate::tabs::ensure_view(self, id);
        self.stack.set_visible_child_name(id);
        self.update_tab_styles();
        if self.visible.get() {
            view.grab_focus();
        }
        if save {
            self.save_settings();
        }
    }

    /// Marca a aba como "usada agora" (zera o relógio de inatividade).
    pub fn touch(&self, id: &str) {
        self.last_active.borrow_mut().insert(id.to_string(), Instant::now());
    }

    pub fn selected_id(&self) -> Option<String> {
        self.settings.borrow().selected_tab.clone()
    }

    // ───────────────────────── persistência / avisos ─────────────────────────

    pub fn save_settings(&self) {
        if let Err(e) = self.settings.borrow().save(&self.paths.settings_file) {
            eprintln!("[EasyBar] não consegui salvar as configurações: {e}");
        }
    }

    pub fn notify(&self, title: &str, body: &str) {
        let n = gtk::gio::Notification::new(title);
        n.set_body(Some(body));
        self.gtk_app.send_notification(None, &n);
        eprintln!("[EasyBar] {title}: {body}");
    }

    pub fn apply_hotkey(self: &Rc<Self>) {
        let text = self.settings.borrow().hotkey.clone();
        match Hotkey::parse(&text) {
            Some(hk) => crate::hotkey::bind(self, hk),
            None => self.notify("EasyBar", &format!("Atalho inválido: \"{text}\". Use algo como Alt+Q.")),
        }
    }

    // ───────────────────────── painel: mostrar / esconder ─────────────────────────

    fn monitors(&self) -> (Rect, Vec<Rect>) {
        let display = gdk::Display::default().expect("sem display gráfico");
        let rect = |m: &gdk::Monitor| {
            let g = m.geometry();
            Rect::new(f64::from(g.x()), f64::from(g.y()), f64::from(g.width()), f64::from(g.height()))
        };
        let primary = display
            .primary_monitor()
            .or_else(|| display.monitor(0))
            .expect("sem monitor");
        let main = rect(&primary);
        let others = (0..display.n_monitors())
            .filter_map(|i| display.monitor(i))
            .map(|m| rect(&m))
            .filter(|r| *r != main)
            .collect();
        (main, others)
    }

    /// (monitor principal, frame aberto, frame escondido rente à borda, recortar?)
    fn frames(&self) -> (Rect, Rect, Rect, bool) {
        let (main, others) = self.monitors();
        let s = self.settings.borrow();
        let vis = geometry::visible_frame(&main, s.direction, s.width_percent, s.height_percent, s.vertical_offset_percent);
        let flush = geometry::flush_hidden_frame(&main, s.direction, &vis);
        // A janela fica SEMPRE dentro do monitor principal (o gerenciador de janelas do
        // Cinnamon não deixa janelas fora da tela): o deslize é sempre recortado.
        let _ = &others;
        let clipped = true;
        (main, vis, flush, clipped)
    }

    pub fn toggle(self: &Rc<Self>) {
        dbg(format!("toggle (visible={})", self.visible.get()));
        if self.visible.get() { self.hide_panel() } else { self.show_panel() }
    }

    pub fn show_panel(self: &Rc<Self>) {
        let (main, vis, flush, clipped) = self.frames();
        dbg(format!("show_panel: monitor={main:?} aberto={vis:?} escondido={flush:?} recorte={clipped}"));
        self.visible.set(true);
        // Se a aba aberta tinha sido descarregada, volta sozinha.
        if let Some(id) = self.selected_id() {
            self.touch(&id);
            let view = crate::tabs::ensure_view(self, &id);
            self.stack.set_visible_child_name(&id);
            self.update_tab_styles();
            let _ = view;
        }
        let from = self.last_full.get().unwrap_or(flush);
        self.run_slide(from, vis, 0.28, geometry::ease_out, clipped, main, false);
    }

    pub fn hide_panel(self: &Rc<Self>) {
        let (main, vis, flush, clipped) = self.frames();
        dbg("hide_panel");
        self.visible.set(false);
        let from = self.last_full.get().unwrap_or(vis);
        self.run_slide(from, flush, 0.22, geometry::ease_in, clipped, main, true);
    }

    /// Reaplica tamanho/posição (depois de mudar largura, altura, direção…).
    pub fn reapply_geometry(self: &Rc<Self>) {
        self.hide_icon
            .set_from_icon_name(Some(hide_icon_name(self.settings.borrow().direction)), gtk::IconSize::Button);
        let (_, vis, flush, _) = self.frames();
        self.cancel_slide();
        self.applied.set(None);
        self.root.set_size_request(vis.w as i32, vis.h as i32);
        if self.visible.get() {
            self.window.resize(vis.w as i32, vis.h as i32);
            self.window.move_(vis.x as i32, vis.y as i32);
            self.last_full.set(Some(vis));
        } else {
            self.last_full.set(Some(flush));
        }
    }

    fn cancel_slide(&self) {
        let id = self.slide_source.borrow_mut().take();
        if let Some(id) = id {
            id.remove();
        }
    }

    /// Anima o painel de `from` até `to` (frames COMPLETOS). Com `clipped`, a janela
    /// é recortada na borda do monitor principal e nunca aparece no vizinho.
    #[allow(clippy::too_many_arguments)]
    fn run_slide(
        self: &Rc<Self>,
        from: Rect,
        to: Rect,
        secs: f64,
        ease: fn(f64) -> f64,
        clipped: bool,
        main: Rect,
        hiding: bool,
    ) {
        self.cancel_slide();
        // O conteúdo mantém SEMPRE o tamanho cheio (sem reflow durante o deslize).
        self.root.set_size_request(to.w as i32, to.h as i32);
        self.apply_slide_frame(&from, clipped, &main);
        if !self.window.is_visible() {
            // O relógio de quadros só corre com a janela mapeada: mostra o primeiro
            // pedacinho visível (poucos pixels) para o deslize poder começar.
            for k in 1..=200 {
                let probe = geometry::lerp(&from, &to, f64::from(k) / 200.0);
                if geometry::clip(&probe, &main).is_some() {
                    self.apply_slide_frame(&probe, clipped, &main);
                    break;
                }
            }
        }

        // Sincronizado com o relógio de quadros do monitor: 1 atualização por quadro
        // (um timer fixo de 8 ms enchia o gerenciador de janelas de pedidos → engasgos).
        // O relógio começa no primeiro quadro: a primeira abertura da sessão custa um
        // render pesado e, senão, "engoliria" o começo da animação.
        let start: Cell<Option<i64>> = Cell::new(None);
        let app = self.clone();
        let id = self.window.add_tick_callback(move |_, clock| {
            let now = clock.frame_time();
            let st = start.get().unwrap_or_else(|| {
                start.set(Some(now));
                now
            });
            let t = (((now - st) as f64) / 1_000_000.0 / secs).clamp(0.0, 1.0);
            let full = geometry::lerp(&from, &to, ease(t));
            app.last_full.set(Some(full));
            app.apply_slide_frame(&full, clipped, &main);
            if t >= 1.0 {
                // o Break remove a fonte: só esquecemos o id
                app.slide_source.borrow_mut().take();
                app.finish_slide(&to, hiding);
                return glib::ControlFlow::Break;
            }
            glib::ControlFlow::Continue
        });
        *self.slide_source.borrow_mut() = Some(id);
    }

    /// Posiciona a janela no recorte do frame completo `full` que está DENTRO do monitor
    /// principal e rola o conteúdo para mostrar a fatia certa (mesmo princípio do Mac).
    fn apply_slide_frame(&self, full: &Rect, _clipped: bool, main: &Rect) {
        match geometry::clip(full, main) {
            None => {
                // Totalmente fora do monitor (início/fim do deslize): mantém a janela como
                // está. NÃO esconder aqui — sem janela mapeada o relógio de quadros para e a
                // animação morre; quem esconde é `finish_slide`, ao terminar de fechar.
            }
            Some((win, local)) => {
                let (wi, hi) = (win.w.round().max(1.0), win.h.round().max(1.0));
                let rect = (win.x.round() as i32, win.y.round() as i32, wi as i32, hi as i32);
                let same_geometry = self.applied.get() == Some(rect);
                // Configura os limites junto com o valor: o Viewport só atualiza os dele
                // depois da alocação, e o valor seria cortado com os limites antigos.
                self.scroller.hadjustment().configure(local.x, 0.0, full.w, 1.0, 10.0, wi);
                self.scroller.vadjustment().configure(local.y, 0.0, full.h, 1.0, 10.0, hi);
                if !same_geometry {
                    self.applied.set(Some(rect));
                    self.window.resize(rect.2, rect.3);
                    self.window.move_(rect.0, rect.1);
                }
                if !self.window.is_visible() {
                    self.window.show();
                    self.window.set_keep_above(true);
                }
            }
        }
    }

    fn finish_slide(self: &Rc<Self>, to: &Rect, hiding: bool) {
        dbg(format!("fim do deslize: hiding={hiding} destino={to:?}"));
        self.last_full.set(Some(*to));
        if hiding {
            // Sai da tela de verdade (antes só deslizava e ficava "aberta" fora da borda).
            self.window.hide();
            self.applied.set(None);
        } else {
            self.focus_panel();
        }
    }

    fn focus_panel(&self) {
        // Sem um timestamp válido o gerenciador de janelas pode negar o foco
        // ("prevenção de roubo de foco"); o horário do servidor X resolve.
        let ts = self
            .window
            .window()
            .and_then(|w| w.downcast::<gdkx11::X11Window>().ok())
            .map(|w| gdkx11::functions::x11_get_server_time(&w));
        match ts {
            Some(t) => self.window.present_with_time(t),
            None => self.window.present(),
        }
        if let Some(view) = self.selected_id().and_then(|id| self.views.borrow().get(&id).cloned()) {
            view.grab_focus();
        }
    }
}

impl App {
    /// Título sugerido a partir do endereço (ex.: "https://www.gemini.google.com" → "gemini.google.com").
    pub fn host_title(url: &str) -> String {
        let rest = url.split_once("://").map_or(url, |(_, r)| r);
        let host = rest.split(['/', '?', '#']).next().unwrap_or(rest);
        host.trim_start_matches("www.").to_string()
    }
}

pub fn hide_icon_name(dir: Direction) -> &'static str {
    match dir {
        Direction::RightToLeft => "go-next-symbolic",
        Direction::LeftToRight => "go-previous-symbolic",
        Direction::TopToBottom => "go-up-symbolic",
        Direction::BottomToTop => "go-down-symbolic",
    }
}

fn short_title(title: &str) -> String {
    let t = title.trim();
    if t.is_empty() { "…".to_string() } else { t.chars().take(12).collect() }
}

/// Ícone da aba: o favicon importado/capturado ou um ícone genérico.
pub fn tab_icon(tab: &Tab) -> gtk::Image {
    if let Some(pb) = tab.favicon.as_deref().and_then(decode_icon) {
        return gtk::Image::from_pixbuf(Some(&pb));
    }
    gtk::Image::from_icon_name(Some("applications-internet"), gtk::IconSize::LargeToolbar)
}

pub fn decode_icon(b64: &str) -> Option<gtk::gdk_pixbuf::Pixbuf> {
    let bytes = glib::base64_decode(b64.trim());
    if bytes.is_empty() {
        return None;
    }
    let loader = gtk::gdk_pixbuf::PixbufLoader::new();
    loader.write(&bytes).ok()?;
    loader.close().ok()?;
    loader.pixbuf()?.scale_simple(22, 22, gtk::gdk_pixbuf::InterpType::Bilinear)
}
