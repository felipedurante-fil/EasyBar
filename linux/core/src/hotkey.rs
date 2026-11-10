//! Atalho global: texto "Alt+Q" ⇄ estrutura, e tradução do atalho salvo no Mac
//! (código de tecla virtual do macOS + máscara de modificadores).

use std::fmt;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Hotkey {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    /// Tecla "Super" (Windows) — equivale ao Command do Mac.
    pub super_key: bool,
    /// Nome do keysym X11 (`q`, `F5`, `space`, `minus`…).
    pub key: String,
}

impl Hotkey {
    pub fn parse(text: &str) -> Option<Hotkey> {
        let mut hk = Hotkey { ctrl: false, alt: false, shift: false, super_key: false, key: String::new() };
        for raw in text.split('+') {
            let part = raw.trim();
            if part.is_empty() {
                return None;
            }
            match part.to_ascii_lowercase().as_str() {
                "ctrl" | "control" | "ctl" => hk.ctrl = true,
                "alt" | "option" | "opt" => hk.alt = true,
                "shift" => hk.shift = true,
                "super" | "win" | "windows" | "meta" | "cmd" | "command" => hk.super_key = true,
                _ => {
                    if !hk.key.is_empty() {
                        return None; // duas teclas "normais"
                    }
                    hk.key = canonical_key(part)?;
                }
            }
        }
        if hk.key.is_empty() || !(hk.ctrl || hk.alt || hk.shift || hk.super_key) {
            return None; // exige ao menos um modificador (senão sequestraria a tecla)
        }
        Some(hk)
    }

    pub fn has_modifier(&self) -> bool {
        self.ctrl || self.alt || self.shift || self.super_key
    }
}

impl fmt::Display for Hotkey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut parts: Vec<String> = Vec::new();
        if self.ctrl { parts.push("Ctrl".into()); }
        if self.alt { parts.push("Alt".into()); }
        if self.shift { parts.push("Shift".into()); }
        if self.super_key { parts.push("Super".into()); }
        parts.push(if self.key.chars().count() == 1 { self.key.to_uppercase() } else { self.key.clone() });
        write!(f, "{}", parts.join("+"))
    }
}

/// Normaliza o nome da tecla para o nome do keysym X11.
fn canonical_key(name: &str) -> Option<String> {
    let lower = name.to_ascii_lowercase();
    // letras e dígitos
    if lower.chars().count() == 1 {
        let c = lower.chars().next()?;
        if c.is_ascii_alphanumeric() {
            return Some(lower);
        }
        // pontuação digitada como símbolo
        return Some(match c {
            '-' => "minus", '=' => "equal", '[' => "bracketleft", ']' => "bracketright",
            ';' => "semicolon", '\'' => "apostrophe", '\\' => "backslash", ',' => "comma",
            '/' => "slash", '.' => "period", '`' => "grave", _ => return None,
        }.to_string());
    }
    // F1..F12
    if let Some(n) = lower.strip_prefix('f').and_then(|r| r.parse::<u8>().ok()) {
        if (1..=12).contains(&n) {
            return Some(format!("F{n}"));
        }
    }
    Some(match lower.as_str() {
        "space" | "espaco" | "espaço" => "space",
        "return" | "enter" => "Return",
        "tab" => "Tab",
        "escape" | "esc" => "Escape",
        "backspace" | "delete" => "BackSpace",
        "left" => "Left", "right" => "Right", "up" => "Up", "down" => "Down",
        "minus" | "equal" | "bracketleft" | "bracketright" | "semicolon" | "apostrophe"
        | "backslash" | "comma" | "slash" | "period" | "grave" => return Some(lower),
        _ => return None,
    }.to_string())
}

// Códigos de tecla virtual do macOS (layout ANSI) → nome do keysym.
const MAC_KEYS: &[(i64, &str)] = &[
    (0, "a"), (1, "s"), (2, "d"), (3, "f"), (4, "h"), (5, "g"), (6, "z"), (7, "x"), (8, "c"),
    (9, "v"), (11, "b"), (12, "q"), (13, "w"), (14, "e"), (15, "r"), (16, "y"), (17, "t"),
    (18, "1"), (19, "2"), (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "equal"), (25, "9"),
    (26, "7"), (27, "minus"), (28, "8"), (29, "0"), (30, "bracketright"), (31, "o"), (32, "u"),
    (33, "bracketleft"), (34, "i"), (35, "p"), (36, "Return"), (37, "l"), (38, "j"),
    (39, "apostrophe"), (40, "k"), (41, "semicolon"), (42, "backslash"), (43, "comma"),
    (44, "slash"), (45, "n"), (46, "m"), (47, "period"), (48, "Tab"), (49, "space"),
    (50, "grave"), (51, "BackSpace"), (53, "Escape"),
    (122, "F1"), (120, "F2"), (99, "F3"), (118, "F4"), (96, "F5"), (97, "F6"), (98, "F7"),
    (100, "F8"), (101, "F9"), (109, "F10"), (103, "F11"), (111, "F12"),
    (123, "Left"), (124, "Right"), (125, "Down"), (126, "Up"),
];

// Modificadores. O app do Mac guarda uma mistura de máscaras Carbon
// (cmd 256, shift 512, option 2048, control 4096) e NSEvent (shift 1<<17,
// control 1<<18, option 1<<19, command 1<<20): aceitamos as duas famílias.
const SHIFT_BITS: u64 = 512 | (1 << 17);
const CTRL_BITS: u64 = 4096 | (1 << 18);
const OPTION_BITS: u64 = 2048 | (1 << 19);
const COMMAND_BITS: u64 = 256 | (1 << 20);

/// Atalho salvo pelo app do Mac → atalho do Linux. `None` se a tecla não tem equivalente.
pub fn from_mac(key_code: i64, modifiers: u64) -> Option<Hotkey> {
    let key = MAC_KEYS.iter().find(|(c, _)| *c == key_code)?.1.to_string();
    let hk = Hotkey {
        ctrl: modifiers & CTRL_BITS != 0,
        alt: modifiers & OPTION_BITS != 0,
        shift: modifiers & SHIFT_BITS != 0,
        super_key: modifiers & COMMAND_BITS != 0,
        key,
    };
    hk.has_modifier().then_some(hk)
}

/// Linux → valores no formato que o app do Mac lê (enum `HotKeyModifier` dele:
/// option 2048, control 4096, shift 131072, command 256).
pub fn to_mac(hk: &Hotkey) -> Option<(i64, u64)> {
    let code = MAC_KEYS.iter().find(|(_, k)| *k == hk.key)?.0;
    let mut mods = 0u64;
    if hk.alt { mods |= 2048; }
    if hk.ctrl { mods |= 4096; }
    if hk.shift { mods |= 131072; }
    if hk.super_key { mods |= 256; }
    Some((code, mods))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn option_q_do_mac_vira_alt_q() {
        // Padrão do app do Mac: keyCode 12 (Q) + option (2048).
        let hk = from_mac(12, 2048).unwrap();
        assert_eq!(hk.to_string(), "Alt+Q");
        assert_eq!(hk, Hotkey::parse("Alt+Q").unwrap());
    }

    #[test]
    fn modificadores_das_duas_familias() {
        let hk = from_mac(14, (1 << 20) | (1 << 17)).unwrap(); // NSEvent: command+shift, E
        assert!(hk.super_key && hk.shift && !hk.alt && !hk.ctrl);
        assert_eq!(hk.to_string(), "Shift+Super+E");
        let carbon = from_mac(14, 256 | 512 | 4096).unwrap(); // Carbon: cmd+shift+control
        assert!(carbon.super_key && carbon.shift && carbon.ctrl);
    }

    #[test]
    fn sem_modificador_ou_tecla_desconhecida_nao_traduz() {
        assert!(from_mac(12, 0).is_none(), "sem modificador sequestraria a tecla");
        assert!(from_mac(9999, 2048).is_none());
    }

    #[test]
    fn parse_aceita_variacoes_e_rejeita_lixo() {
        assert_eq!(Hotkey::parse("ctrl + shift + e").unwrap().to_string(), "Ctrl+Shift+E");
        assert_eq!(Hotkey::parse("Option+F5").unwrap().to_string(), "Alt+F5");
        assert_eq!(Hotkey::parse("Cmd+space").unwrap().to_string(), "Super+space");
        assert_eq!(Hotkey::parse("Alt+-").unwrap().key, "minus");
        assert!(Hotkey::parse("Q").is_none(), "precisa de modificador");
        assert!(Hotkey::parse("Alt+").is_none());
        assert!(Hotkey::parse("Alt+Q+W").is_none());
        assert!(Hotkey::parse("Alt+F13").is_none());
        assert!(Hotkey::parse("").is_none());
    }

    #[test]
    fn ida_e_volta_texto() {
        for t in ["Alt+Q", "Ctrl+Alt+Delete".replace("Delete", "BackSpace").as_str(), "Super+Return", "Shift+F12"] {
            let hk = Hotkey::parse(t).unwrap();
            assert_eq!(Hotkey::parse(&hk.to_string()).unwrap(), hk, "{t}");
        }
    }

    #[test]
    fn exportar_para_o_mac_usa_os_valores_do_enum_dele() {
        let (code, mods) = to_mac(&Hotkey::parse("Alt+Q").unwrap()).unwrap();
        assert_eq!((code, mods), (12, 2048));
        let (_, m2) = to_mac(&Hotkey::parse("Ctrl+Shift+Super+Alt+Q").unwrap()).unwrap();
        assert_eq!(m2, 2048 | 4096 | 131072 | 256);
        // e o que o Mac exporta é entendido na volta
        assert_eq!(from_mac(12, m2).unwrap().to_string(), "Ctrl+Alt+Shift+Super+Q");
    }
}
