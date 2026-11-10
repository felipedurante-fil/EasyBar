//! Dados de navegação: uso de disco, limpar cache (mantendo logins) e gerenciar por site.

use crate::app::App;
use crate::config::dir_size;
use futures_channel::oneshot;
use gtk::glib;
use std::rc::Rc;
use webkit2gtk::{WebContextExt, WebsiteData, WebsiteDataManagerExt, WebsiteDataManagerExtManual, WebsiteDataTypes};

/// O que é só cache (recriável): NÃO inclui cookies, localStorage nem IndexedDB.
pub fn cache_types() -> WebsiteDataTypes {
    WebsiteDataTypes::DISK_CACHE
        | WebsiteDataTypes::MEMORY_CACHE
        | WebsiteDataTypes::OFFLINE_APPLICATION_CACHE
        | WebsiteDataTypes::DOM_CACHE
}

pub struct Usage {
    pub data: u64,
    pub cache: u64,
}

/// Soma o tamanho das pastas numa thread de segundo plano (o cache pode ter milhares de
/// arquivos; fazer isso na thread da interface travaria a janela).
pub fn usage_async(app: &App, done: impl FnOnce(Usage) + 'static) {
    let (data_dir, cache_dir) = (app.paths.web_data.clone(), app.paths.web_cache.clone());
    let (tx, rx) = oneshot::channel();
    std::thread::spawn(move || {
        let _ = tx.send(Usage { data: dir_size(&data_dir), cache: dir_size(&cache_dir) });
    });
    glib::MainContext::default().spawn_local(async move {
        if let Ok(u) = rx.await {
            done(u);
        }
    });
}

fn run_clear(app: &Rc<App>, types: WebsiteDataTypes, done: impl FnOnce(Result<(), String>) + 'static) {
    let (tx, rx) = oneshot::channel();
    app.data_manager.clear(types, glib::TimeSpan(0), None::<&gio::Cancellable>, move |r| {
        let _ = tx.send(r.map_err(|e| e.to_string()));
    });
    glib::MainContext::default().spawn_local(async move {
        match rx.await {
            Ok(r) => done(r),
            Err(_) => done(Err("operação cancelada".into())),
        }
    });
}

/// Limpa só o cache de todos os sites (logins continuam).
pub fn clear_cache(app: &Rc<App>, done: impl FnOnce(Result<(), String>) + 'static) {
    app.web_context.clear_cache();
    run_clear(app, cache_types(), done);
}

/// Apaga TUDO (cookies, logins, armazenamento local…).
pub fn clear_everything(app: &Rc<App>, done: impl FnOnce(Result<(), String>) + 'static) {
    run_clear(app, WebsiteDataTypes::ALL, done);
}

pub struct Site {
    pub name: String,
    pub cache_size: u64,
    pub total_size: u64,
    data: WebsiteData,
}

/// Lista os sites com dados guardados, do maior para o menor.
pub fn fetch_sites(app: &Rc<App>, done: impl FnOnce(Result<Vec<Site>, String>) + 'static) {
    let fut = app.data_manager.fetch_future(WebsiteDataTypes::ALL);
    glib::MainContext::default().spawn_local(async move {
        match fut.await {
            Err(e) => done(Err(e.to_string())),
            Ok(list) => {
                let mut sites: Vec<Site> = list
                    .into_iter()
                    .map(|d| Site {
                        name: d.name().map(|n| n.to_string()).unwrap_or_default(),
                        cache_size: d.size(cache_types()),
                        total_size: d.size(WebsiteDataTypes::ALL),
                        data: d,
                    })
                    .filter(|s| !s.name.is_empty())
                    .collect();
                sites.sort_by(|a, b| b.total_size.cmp(&a.total_size));
                done(Ok(sites));
            }
        }
    });
}

pub fn clear_site(app: &Rc<App>, site: &Site, types: WebsiteDataTypes, done: impl FnOnce(Result<(), String>) + 'static) {
    let (tx, rx) = oneshot::channel();
    // `WebsiteData` não é Send; o callback só roda na thread principal, mas o
    // trait exige Send → passamos apenas o resultado pelo canal.
    app.data_manager.remove(types, &[&site.data], None::<&gio::Cancellable>, move |r| {
        let _ = tx.send(r.map_err(|e| e.to_string()));
    });
    glib::MainContext::default().spawn_local(async move {
        match rx.await {
            Ok(r) => done(r),
            Err(_) => done(Err("operação cancelada".into())),
        }
    });
}
