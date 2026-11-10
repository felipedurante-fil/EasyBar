//! Geometria do painel deslizante. Coordenadas de tela X11/GDK: origem no canto
//! SUPERIOR esquerdo, y cresce para baixo.
//!
//! Esconder = deslizar para fora da borda do monitor. Se houver OUTRO monitor
//! ao lado dessa borda, o painel "escondido" cairia dentro dele — por isso o
//! deslize pode ser **recortado**: a janela é cortada na borda do monitor
//! principal (frame completo ∩ monitor) e nunca aparece no vizinho.

use crate::model::Direction;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }
    pub fn right(&self) -> f64 { self.x + self.w }
    pub fn bottom(&self) -> f64 { self.y + self.h }

    /// Interseção com área > 0 (retângulos apenas encostados NÃO se intersectam).
    pub fn intersection(&self, o: &Rect) -> Option<Rect> {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let r = self.right().min(o.right());
        let b = self.bottom().min(o.bottom());
        (r > x && b > y).then(|| Rect::new(x, y, r - x, b - y))
    }
    pub fn intersects(&self, o: &Rect) -> bool {
        self.intersection(o).is_some()
    }
    pub fn translated(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.w, self.h)
    }
}

/// Painel aberto: encostado na borda do monitor.
pub fn visible_frame(mon: &Rect, dir: Direction, width_pct: f64, height_pct: f64, v_offset_pct: f64) -> Rect {
    let w = (mon.w * width_pct.clamp(0.01, 1.0)).round();
    let h = (mon.h * height_pct.clamp(0.01, 1.0)).round();
    let v_off = (mon.h * v_offset_pct.clamp(0.0, 0.5)).round();
    match dir {
        Direction::LeftToRight => Rect::new(mon.x, mon.y + v_off, w, h),
        Direction::RightToLeft => Rect::new(mon.right() - w, mon.y + v_off, w, h),
        Direction::TopToBottom => Rect::new(mon.x + ((mon.w - w) / 2.0).floor(), mon.y, w, h),
        Direction::BottomToTop => Rect::new(mon.x + ((mon.w - w) / 2.0).floor(), mon.bottom() - h, w, h),
    }
}

/// Painel escondido, rente à borda (fora do monitor, sem folga).
pub fn flush_hidden_frame(mon: &Rect, dir: Direction, visible: &Rect) -> Rect {
    match dir {
        Direction::LeftToRight => Rect::new(mon.x - visible.w, visible.y, visible.w, visible.h),
        Direction::RightToLeft => Rect::new(mon.right(), visible.y, visible.w, visible.h),
        Direction::TopToBottom => Rect::new(visible.x, mon.y - visible.h, visible.w, visible.h),
        Direction::BottomToTop => Rect::new(visible.x, mon.bottom(), visible.w, visible.h),
    }
}

/// O painel "escondido" cairia dentro de algum outro monitor? (Sonda com 20 px de
/// folga para fora da borda, como o app do Mac.)
pub fn hidden_collides(flush_hidden: &Rect, dir: Direction, other_monitors: &[Rect]) -> bool {
    let (dx, dy) = match dir {
        Direction::LeftToRight => (-20.0, 0.0),
        Direction::RightToLeft => (20.0, 0.0),
        Direction::TopToBottom => (0.0, -20.0),
        Direction::BottomToTop => (0.0, 20.0),
    };
    let probe = flush_hidden.translated(dx, dy);
    other_monitors.iter().any(|m| m.intersects(&probe))
}

/// Parte do frame completo que está DENTRO do monitor principal, e essa mesma
/// parte em coordenadas locais da janela (para a região de recorte).
pub fn clip(full: &Rect, mon: &Rect) -> Option<(Rect, Rect)> {
    let v = full.intersection(mon)?;
    if v.w < 1.0 || v.h < 1.0 {
        return None;
    }
    Some((v, Rect::new(v.x - full.x, v.y - full.y, v.w, v.h)))
}

pub fn ease_out(t: f64) -> f64 { 1.0 - (1.0 - t.clamp(0.0, 1.0)).powi(3) }
pub fn ease_in(t: f64) -> f64 { t.clamp(0.0, 1.0).powf(2.2) }

/// Frame completo interpolado entre `from` e `to` (mesmo tamanho).
pub fn lerp(from: &Rect, to: &Rect, e: f64) -> Rect {
    Rect::new(from.x + (to.x - from.x) * e, from.y + (to.y - from.y) * e, to.w, to.h)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Layout real do usuário, convertido para y-para-baixo:
    // principal 1470x956 em (0,0); vizinho 1280x720 à direita, mais baixo (y=0..720 aqui).
    const MAIN: Rect = Rect::new(0.0, 0.0, 1470.0, 956.0);
    const SIDE: Rect = Rect::new(1470.0, 0.0, 1280.0, 720.0);

    #[test]
    fn frame_visivel_nas_quatro_direcoes() {
        let v = visible_frame(&MAIN, Direction::RightToLeft, 0.7, 0.8, 0.1);
        assert_eq!(v, Rect::new(1470.0 - 1029.0, 96.0, 1029.0, 765.0));
        assert_eq!(v.right(), MAIN.right(), "colado na borda direita");
        let l = visible_frame(&MAIN, Direction::LeftToRight, 0.7, 0.8, 0.1);
        assert_eq!((l.x, l.y), (0.0, 96.0));
        let t = visible_frame(&MAIN, Direction::TopToBottom, 0.7, 0.8, 0.1);
        assert_eq!((t.y, t.x), (0.0, ((1470.0 - 1029.0) / 2.0f64).floor()));
        let b = visible_frame(&MAIN, Direction::BottomToTop, 0.7, 0.8, 0.1);
        assert_eq!(b.bottom(), MAIN.bottom());
    }

    #[test]
    fn frame_escondido_rente_a_borda() {
        for dir in Direction::ALL {
            let vis = visible_frame(&MAIN, dir, 0.7, 0.8, 0.1);
            let hid = flush_hidden_frame(&MAIN, dir, &vis);
            assert_eq!((hid.w, hid.h), (vis.w, vis.h));
            assert!(!hid.intersects(&MAIN), "{dir:?}: escondido não pode tocar o monitor");
            assert!(clip(&hid, &MAIN).is_none(), "{dir:?}: nada dentro do monitor");
        }
    }

    #[test]
    fn detecta_monitor_vizinho_na_borda_do_deslize() {
        let vis = visible_frame(&MAIN, Direction::RightToLeft, 0.7, 0.8, 0.1);
        let hid = flush_hidden_frame(&MAIN, Direction::RightToLeft, &vis);
        assert!(hidden_collides(&hid, Direction::RightToLeft, &[SIDE]), "caso do print do usuário");
        assert!(!hidden_collides(&hid, Direction::RightToLeft, &[]));
        let vis_l = visible_frame(&MAIN, Direction::LeftToRight, 0.7, 0.8, 0.1);
        let hid_l = flush_hidden_frame(&MAIN, Direction::LeftToRight, &vis_l);
        assert!(!hidden_collides(&hid_l, Direction::LeftToRight, &[SIDE]), "vizinho à direita não atrapalha o deslize pela esquerda");
        // vizinho só mais alto que o painel (sem sobreposição vertical) também não colide
        let far = Rect::new(1470.0, 2000.0, 1280.0, 720.0);
        assert!(!hidden_collides(&hid, Direction::RightToLeft, &[far]));
    }

    #[test]
    fn recorte_da_interseccao() {
        let full = Rect::new(1200.0, 100.0, 1000.0, 700.0); // metade fora, à direita
        let (win, local) = clip(&full, &MAIN).unwrap();
        assert_eq!(win, Rect::new(1200.0, 100.0, 270.0, 700.0));
        assert_eq!(local, Rect::new(0.0, 0.0, 270.0, 700.0), "lado ESQUERDO do painel é o que aparece");
        let full_l = Rect::new(-400.0, 100.0, 1000.0, 700.0); // metade fora, à esquerda
        let (win_l, local_l) = clip(&full_l, &MAIN).unwrap();
        assert_eq!(win_l, Rect::new(0.0, 100.0, 600.0, 700.0));
        assert_eq!(local_l, Rect::new(400.0, 0.0, 600.0, 700.0), "lado DIREITO do painel aparece");
        assert!(clip(&Rect::new(1470.0, 100.0, 1000.0, 700.0), &MAIN).is_none());
        assert!(clip(&Rect::new(1469.5, 100.0, 1000.0, 700.0), &MAIN).is_none(), "fresta < 1 px não conta");
    }

    #[test]
    fn deslize_recortado_nunca_invade_o_vizinho() {
        let vis = visible_frame(&MAIN, Direction::RightToLeft, 0.7, 0.8, 0.1);
        let hid = flush_hidden_frame(&MAIN, Direction::RightToLeft, &vis);
        let mut last_w = 0.0;
        for i in 0..=100 {
            let t = i as f64 / 100.0;
            let full = lerp(&hid, &vis, ease_out(t));
            if let Some((win, _)) = clip(&full, &MAIN) {
                assert!(!win.intersects(&SIDE), "t={t}");
                assert!(win.right() <= MAIN.right() + 0.001);
                assert!(win.w >= last_w - 0.001, "a largura só cresce ao abrir");
                last_w = win.w;
            }
        }
        assert!((last_w - vis.w).abs() < 0.5, "termina com o painel inteiro");
    }

    #[test]
    fn easing_extremos() {
        assert_eq!(ease_out(0.0), 0.0);
        assert_eq!(ease_out(1.0), 1.0);
        assert_eq!(ease_in(0.0), 0.0);
        assert!((ease_in(1.0) - 1.0).abs() < 1e-12);
        assert!(ease_out(0.5) > 0.5 && ease_in(0.5) < 0.5);
        assert_eq!(ease_out(7.0), 1.0, "t fora de faixa é limitado");
    }

    #[test]
    fn retangulos_encostados_nao_se_intersectam() {
        assert!(!MAIN.intersects(&SIDE));
        assert!(Rect::new(0.0, 0.0, 10.0, 10.0).intersects(&Rect::new(9.0, 9.0, 10.0, 10.0)));
    }
}
