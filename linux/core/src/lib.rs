//! Lógica pura do EasyBar para Linux — sem GTK, testável em qualquer sistema.
//!
//! O app gráfico (`easybar-app`) é só a "casca" GTK/WebKit; as regras (o que
//! importar do backup do Mac, quando descarregar uma aba, quais URLs são
//! seguras, onde fica o painel…) moram aqui e têm testes.

pub mod backup;
pub mod failure;
pub mod geometry;
pub mod hotkey;
pub mod model;
pub mod policy;
pub mod urls;
