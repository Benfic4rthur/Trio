# Trio

Protótipo de aplicativo nativo macOS em Swift e AppKit, para Apple Silicon e Intel. Amplia a área dos controles de janela por uma sobreposição conservadora. Não altera controles de outros processos, não injeta código e não desativa proteções do macOS.

## Estado atual

Em desenvolvimento. Pesquisa de APIs públicas e Smart Close concluída; cálculo de espaço, configurações e identidade visual em construção. Estudos de tamanho 2×, 3×, 4× e 5× serão escolhidos pelo usuário antes de fixar a aparência do protótipo. As imagens são estudos de aparência, não evidência de compatibilidade.

Ainda não há validação de execução do Trio sobre janelas reais. Não instalar como versão pronta. O encaminhamento HID ao botão vermelho original ainda precisa ser comparado com AXPress na fixture descartável, com o Smart Close ativo.

## Comportamento planejado

- Inicialização silenciosa com a sessão; configurações ao abrir manualmente a mesma instância.
- Dock e barra de menus opcionais. Esconder e encerrar são ações distintas.
- Botão direito no fundo dos controles abre um menu com “Abrir Trio”, sem executar ações da janela.
- Vermelho encaminha um clique ao controle original, para manter o caminho observado pelo Smart Close. Sem fallback silencioso para AXPress.
- Amarelo minimiza. Verde maximiza dentro da área útil e restaura, sem fullscreen.
- Símbolos e crescimento gradual no hover; fechar e minimizar exigem clique.
- Tamanho configurável e limitado por ferramentas próximas e pela geometria disponível.
- Notificações AX/Workspace em vez de polling permanente; identidade da janela revalidada antes de ações.
- Janelas incompatíveis são preservadas. Cobertura inicial restrita à janela ativa até validar o mecanismo.

## Fontes e ferramentas

- [APIs públicas e limitações](docs/API-RESEARCH.md)
- [Investigação do Smart Close](docs/SMART-CLOSE.md)
- `Tools/CompatibilityFixture.swift`: janela AppKit descartável com barra padrão ou personalizada.
- `Tools/GenerateIcon.swift`: gera o ícone localmente, sem serviço de geração.
- `Sources/TrioCore/Layout.swift`: geometria conservadora; testes em `Tests/TrioCoreTests`.

Destino mínimo pretendido: macOS 13. A máquina de desenvolvimento tem macOS 27.2.1 e Apple Silicon. Compilar para Intel não equivale a testar em hardware Intel.

## Backup

Repositório privado. Envios por MCP do GitHub; sem workflows do GitHub Actions, sem tarefas de IA no GitHub e sem builds remotos.
