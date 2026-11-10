//! Política de descarregamento automático de abas inativas (mesma do app do Mac).

use crate::model::{Settings, Tab};
use std::time::Duration;

/// Minutos de inatividade para descarregar `tab`, ou `None` se ela nunca deve
/// ser descarregada. O ajuste da própria aba vence o global.
pub fn effective_auto_suspend_minutes(settings: &Settings, tab: &Tab) -> Option<u32> {
    match tab.auto_suspend_minutes {
        Some(0) => None,
        Some(n) => Some(n),
        None => settings.auto_suspend_enabled.then(|| settings.auto_suspend_minutes.max(1)),
    }
}

/// Estado de uma aba no momento da varredura.
pub struct SweepInput {
    /// Há quanto tempo a aba não é usada.
    pub idle: Duration,
    /// Política efetiva (de `effective_auto_suspend_minutes`).
    pub minutes: Option<u32>,
    /// É a aba que o usuário está vendo agora (painel aberto)?
    pub is_front: bool,
    /// Tocando áudio, usando microfone/câmera, etc.
    pub protected: bool,
    /// Há download em andamento? (destruir o WebView cancelaria o download)
    pub downloading: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum SweepDecision {
    Keep,
    /// Aba ativa/protegida: zera o relógio de inatividade.
    Touch,
    Suspend,
}

pub fn decide(input: &SweepInput) -> SweepDecision {
    let Some(minutes) = input.minutes else { return SweepDecision::Keep };
    if input.downloading {
        return SweepDecision::Keep;
    }
    if input.is_front {
        return SweepDecision::Touch;
    }
    if input.idle < Duration::from_secs(u64::from(minutes) * 60) {
        return SweepDecision::Keep;
    }
    if input.protected {
        return SweepDecision::Touch;
    }
    SweepDecision::Suspend
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(p: Option<u32>) -> Tab {
        let mut t = Tab::new("x", "https://x.com");
        t.auto_suspend_minutes = p;
        t
    }

    #[test]
    fn politica_efetiva() {
        let mut s = Settings { auto_suspend_enabled: true, auto_suspend_minutes: 30, ..Settings::default() };
        assert_eq!(effective_auto_suspend_minutes(&s, &tab(None)), Some(30));
        assert_eq!(effective_auto_suspend_minutes(&s, &tab(Some(0))), None, "0 = nunca");
        assert_eq!(effective_auto_suspend_minutes(&s, &tab(Some(5))), Some(5));
        s.auto_suspend_enabled = false;
        assert_eq!(effective_auto_suspend_minutes(&s, &tab(None)), None, "global desligado");
        assert_eq!(effective_auto_suspend_minutes(&s, &tab(Some(15))), Some(15), "aba com tempo próprio vale mesmo assim");
    }

    fn input(idle_min: u64, minutes: Option<u32>) -> SweepInput {
        SweepInput { idle: Duration::from_secs(idle_min * 60), minutes, is_front: false, protected: false, downloading: false }
    }

    #[test]
    fn decisoes_da_varredura() {
        assert_eq!(decide(&input(10, Some(30))), SweepDecision::Keep, "ainda dentro do prazo");
        assert_eq!(decide(&input(30, Some(30))), SweepDecision::Suspend, "no limite exato");
        assert_eq!(decide(&input(999, None)), SweepDecision::Keep, "nunca descarregar");
        let mut i = input(999, Some(30)); i.is_front = true;
        assert_eq!(decide(&i), SweepDecision::Touch, "aba visível nunca é descarregada");
        let mut i = input(999, Some(30)); i.protected = true;
        assert_eq!(decide(&i), SweepDecision::Touch, "áudio/câmera protegem");
        let mut i = input(999, Some(30)); i.downloading = true;
        assert_eq!(decide(&i), SweepDecision::Keep, "download em andamento");
        let mut i = input(1, Some(30)); i.protected = true;
        assert_eq!(decide(&i), SweepDecision::Keep, "protegida mas ainda dentro do prazo: nada a fazer");
    }
}
