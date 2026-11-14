# Site do Trio

Site estático em português, inglês e espanhol. Feito para revisar localmente antes da integração ao ALLM4. Nenhum deploy no ALLM4 faz parte desta etapa.

```sh
cd site
npm test
npm run build
npm run preview
```

Acesse <http://127.0.0.1:4178>. A prévia fica restrita ao próprio computador. O build gera `dist/`, `/en/`, `/es/`, fontes locais licenciadas e um download local verificado. Não há dependências de runtime nem chamadas de IA.

Os botões atuam somente nas janelas de demonstração do navegador. Fechar e minimizar retornam automaticamente; maximizar restaura ao segundo clique ou após a demonstração. Passar o ponteiro sobre o verde mostra o menu. Teclado: Enter/Espaço aciona o controle, seta para baixo abre as opções do verde e Escape fecha o menu.

O idioma usa a preferência `allm4.language.v1`. Os endereços `/en/` e `/es/` podem ser compartilhados diretamente. O conteúdo e o download local continuam acessíveis sem JavaScript; movimento reduzido preserva a composição sem a cena fixa.

## Versão e download

O build lê a versão e confere SHA-256/tamanho do pacote real. O cliente consulta primeiro a última GitHub Release estável com o arquivo Universal esperado. Se não houver, usa os arquivos públicos de `distribution/` no repositório; se a rede falhar, mantém o pacote local. Nenhum token é enviado ao navegador. As URLs remotas são validadas para o repositório exato.

Ao atualizar o app, gere o novo ZIP com `scripts/package-release.sh`, atualize `distribution/` e o histórico em `CHANGELOG.md`. Atualize também as notas de versão traduzidas em `content.mjs`. O histórico da página é factual e não troca notas antigas por uma versão nova detectada remotamente.

Fontes e licenças: `public/fonts`. ScrollCraft imutável: `public/vendor`. Ícone aprovado: `Resources/TrioIcon.png` no projeto principal. A arte do site é HTML/CSS/SVG, sem geração de imagens paga.

## Verificação

`qa/` contém os ensaios de navegador com Edge isolado. Capturas e relatórios ficam em `qa/artifacts/`, fora do versionamento. Eles verificam layouts, idiomas, teclado, demonstrações, movimento reduzido e o conteúdo real do ZIP, sem controlar aplicativos nativos nem o clipboard do sistema.
