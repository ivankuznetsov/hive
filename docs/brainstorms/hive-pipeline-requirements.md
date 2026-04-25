---
date: 2026-04-24
topic: hive-folder-state-machine-pipeline
---

# Hive: folder-as-agent pipeline поверх Claude Code

## Problem Frame

Ivan в одиночку ведёт 40+ проектов и каждый цикл `/plan → work → /ce-review → /pr-review-toolkit → параллельно codex /review` прогоняет руками в разных вкладках терминала и веб-UI. Это узкое горло: баги, которые ясно как фиксить, не фиксятся днями, потому что уровень ручной оркестрации сжирает время и внимание.

Цель — построить систему, в которой каждый из этих этапов сам выполняется агентом на фоне, пока Ivan периодически заходит и принимает решения («аппрув → двигай вперёд», «отклонить → вернуть назад»), а результаты лежат в markdown-файлах, которые можно открыть, прочитать и при желании отредактировать руками. Не Kanban, не кастомный GUI — Linux way с папками.

Вдохновлён паттерном «folder as agent» Kieran Klaassen (Every / Cora), но идёт дальше: каждый этап закрепляется за стадийной папкой, и переход между папками играет роль человеческого гейта аппрува.

---

## Actors

- A1. Ivan (human owner): единственный пользователь. Пишет идеи, проверяет артефакты на стыках стадий, передвигает папки вперёд, иногда редактирует файлы руками, иногда принудительно перезапускает агента.
- A2. Stage agent (Claude Code headless): процесс `claude -p`, запущенный в cwd = папка-задача. Читает состояние из markdown, делает работу текущей стадии, пишет артефакты, оставляет маркер состояния, завершается.
- A3. Reviewer agent (Claude Code headless): специализация A2, запускается в 4-execute на собранном коде (ce-review, Codex в режиме локального review, pr-review-toolkit). Пишет findings в `.hive/reviews/*.md`.
- A4. Dispatcher daemon (Phase 2 only): один Ruby-процесс в `~/Dev/hive/`, опрашивает `~/Dev/*/.hive/stages/` и на событиях запускает A2/A3. В Phase 1 отсутствует — Ivan сам вызывает `hive run` на конкретной папке.

---

## Key Flows

- F1. **Idea → merged PR (happy path)**
  - **Trigger:** Ivan создаёт `~/Dev/<project>/.hive/stages/1-inbox/<slug>/idea.md` и запускает `hive run <path>` (Phase 1) или просто оставляет папку (Phase 2).
  - **Actors:** A1, A2, A3
  - **Steps:**
    1. В `1-inbox/` A2 читает `idea.md`, генерирует `brainstorm.md` с вопросами и маркером `<!-- WAITING -->`, завершается.
    2. Ivan редактирует `brainstorm.md`, отвечает на вопросы, сохраняет. Повторный запуск A2 (ручной в Phase 1, автоматический от fswatch в Phase 2) читает ответы, пишет следующий раунд или ставит `<!-- COMPLETE -->`.
    3. Ivan переносит папку в `2-brainstorm/` → ошибка: обратный порядок; папка должна сразу быть в `1-inbox/`, и после заполнения brainstorm.md переезжает в `2-brainstorm/`. Уточнение: стадия «brainstorm» — это **целевая** папка, куда попадает задача **после** шторма. См. R3.
    4. То же для `3-plan/` и `4-execute/`.
    5. В `4-execute/` A2 создаёт git worktree в **отдельном** sibling-пути `~/Dev/<project>.worktrees/<slug>/` с новой веткой `<slug>`, записывает pointer `.hive/stages/4-execute/<slug>/worktree.yml` (path + branch), идёт в worktree, имплементит по plan.md, коммитит в фичеветку, возвращается и прогоняет A3-рецензентов на diff'е фичеветки против main. Findings — в `.hive/reviews/ce-review-01.md` внутри task-папки (в main, не в worktree).
    6. Ivan отмечает findings `[x]`/удаляет/оставляет `[ ]`, сохраняет. A2 новый pass: фиксит `[x]`, запускает рецензентов повторно, пишет `reviews/*-02.md`.
    7. Ivan доволен, переносит папку в `5-pr/`. A2 делает `gh pr create`, выводит PR URL. В Phase 3 демон втягивает PR-комменты в `.hive/reviews/pr-comments-*.md`.
    8. PR мёрджится (Ivan вручную в MVP). Папка переносится в `6-done/`. A2 в Phase 3 делает `git worktree remove ~/Dev/<project>.worktrees/<slug>`, удаляет merged-ветку, экспортирует артефакты task-папки в QMD-коллекцию. `.hive/`-изменения коммитятся в main обычным hive-коммитом.
  - **Outcome:** PR слит, задача в `6-done/` с полной историей рассуждений, worktree очищен, знание проиндексировано для поиска будущих задач.
  - **Covered by:** R1, R2, R3, R4, R5, R6, R7, R8, R11, R12, R15

- F2. **Review iteration loop внутри 4-execute**
  - **Trigger:** A2 закончил build pass, оставил `<!-- EXECUTE_WAITING -->` и findings в `reviews/*-NN.md`.
  - **Actors:** A1, A2, A3
  - **Steps:**
    1. Ivan открывает `.hive/reviews/`. Для каждого finding: `[x]` (принять), оставить `[ ]` (игнорировать в этом pass), удалить строку (отклонить совсем). Можно прибавить `<!-- skip: reason -->`.
    2. Сохраняет → новый триггер → A2 читает все `reviews/*-NN.md`, выделяет `[x]`, фиксит в коде, коммитит.
    3. Прогоняет A3-рецензентов снова, пишет `reviews/*-(NN+1).md`.
    4. Если новые findings → `<!-- EXECUTE_WAITING -->`. Если все чисто → `<!-- EXECUTE_COMPLETE -->`.
    5. На 5-м pass (настраивается) A2 ставит `<!-- EXECUTE_STALE max_passes=4 -->` и останавливается — дальше только `hive execute --force`.
  - **Outcome:** Ivan либо идёт в 5-pr/ с принятой серией фиксов, либо имеет ясный stale-маркер для разбора руками.
  - **Covered by:** R6, R7, R8

- F3. **Принудительное вмешательство на любой стадии**
  - **Trigger:** Агент написал херню, Ivan хочет переписать руками.
  - **Actors:** A1
  - **Steps:**
    1. Ivan открывает файл (например, `plan.md`), правит.
    2. Либо запускает `hive run` повторно (агент видит обновлённый файл, продолжает с него), либо оставляет как есть и двигает папку вперёд.
  - **Outcome:** Система не мешает ручному редактированию — это ядро «Linux way».
  - **Covered by:** R2, R9, R14

---

## Requirements

**Структура и хранение**

- R1. Каждый проект, подключённый к hive, имеет папку `.hive/` в корне репозитория, содержащую `stages/1-inbox/`, `stages/2-brainstorm/`, `stages/3-plan/`, `stages/4-execute/`, `stages/5-pr/`, `stages/6-done/` и `config.yml`.
- R2. Единицей задачи является папка внутри одной из stage-папок. Внутри task-папки лежат только артефакты (`idea.md`, `brainstorm.md`, `plan.md`, `reviews/*.md`, `logs/`, и начиная с 4-execute — `worktree.yml` pointer). Реальный код **не** живёт внутри task-папки — он в отдельном git worktree по отдельному пути.
- R3. Стадия задачи определяется только тем, в какой stage-папке лежит её папка. Перемещение между стадиями — ручное действие Ivan'а (`mv`), которое семантически = аппрув предыдущей стадии + запуск следующей.

**Agent-human протокол**

- R4. Межстадийное общение идёт через HTML-коммент-маркеры в markdown-файле текущей стадии: `<!-- AGENT_WORKING pid=N started=ISO -->`, `<!-- WAITING -->`, `<!-- COMPLETE -->`, `<!-- ERROR ... -->`, `<!-- EXECUTE_STALE max_passes=N -->`.
- R5. Интерактивный Q&A для брейнштормов работает так: агент дописывает `## Round N`-секцию с вопросами и оставляет `<!-- WAITING -->`. Ivan правит inline (чекбоксы `[x]`, дописывает ответы), сохраняет. Следующий запуск агента парсит ответы и либо пишет `## Round N+1`, либо финальный `## Requirements` + `<!-- COMPLETE -->`.

**Code review iteration**

- R6. Рецензенты (ce-review и дополнительно Codex/pr-review-toolkit/rubocop/etc) пишут findings в `.hive/reviews/<reviewer>-<pass>.md` как списки `- [ ] <finding>`.
- R7. Ivan триажит, ставя `[x]` (принять), оставляя `[ ]` (игнорить в этом pass) или удаляя строку (отклонить совсем). Может дописывать `<!-- skip: reason -->` как аннотацию.
- R8. После редактирования findings-файла агент делает новый execute-pass: читает все `[x]` across reviewer-файлов, применяет фиксы, прогоняет рецензентов повторно, пишет `<reviewer>-<pass+1>.md`. Максимум 4 pass'а (настраиваемо); после — `EXECUTE_STALE`, требует ручного `--force`.

**Запуск и оркестрация**

- R9. В Phase 1 (MVP) все агенты запускаются руками через CLI: `hive run <folder>`. Никакого демона нет. Ivan сам выбирает, когда что стартовать.
- R10. В Phase 2 появляется дисаптчер-демон в `~/Dev/hive/daemon.rb`, который работает polling-ом (раз в 30–60 с) + fswatch для ускоренного реагирования. Демон пропускает папки с активным `.hive/.lock` и маркером `AGENT_WORKING`.
- R11. Агент запускается как subprocess `claude -p` с cwd = папка-задача. Claude Code автоматически подхватывает проектные `CLAUDE.md`, `.claude/skills/`, `.claude/agents/`, `.claude/settings.json` из пути проекта — это делает «папку агентом» без дополнительного кода.

**Worktree и лайфсайкл**

- R12. Git worktree создаётся **только при входе в 4-execute** и живёт в `~/Dev/<project>.worktrees/<slug>/` (sibling main checkout'а, по умолчанию; путь переопределяется в `~/Dev/hive/config.yml`). Агент делает `git worktree add ~/Dev/<project>.worktrees/<slug> -b <slug>` из main checkout'а, записывает pointer `worktree.yml` в task-папку и дальше работает cross-path: читает/пишет артефакты в main (task-папка), правит код в worktree.
- R13. После merge PR папка переносится в `6-done/`. В Phase 3 это триггерит `git worktree remove` по path'у из `worktree.yml`, удаление merged-ветки и экспорт task-артефактов в QMD-коллекцию (например, `<project>-learnings` или общий `hive-learnings`). В MVP архивация делается руками.
- R16. `.hive/` папка **коммитится в main-ветку** проекта (**не** в feature-ветку, **не** через PR). Коммиты делаются автоматически агентом после каждого run'а стадии с сообщением формата `hive: <stage>/<slug> <action>` (напр. `hive: 3-plan/fix-1765 plan ready`). Это даёт `git log main` как audit trail всей работы: хронологию «что было на входе, что обсуждалось, какие findings приняты». Commits помечены `[skip ci]` чтобы не триггерить CI. `.hive/` **не** попадает в feature-ветку (feature worktree создаётся из main без .hive-staged-файлов либо .hive/ в feature явно исключается через .gitattributes/checkout filters). Никакого squash-мёрджа для hive — он живёт прямыми коммитами в main.

**Control plane**

- R14. `~/Dev/hive/` — не stage machine, а тонкий control plane: `config.yml` (список активных проектов), `bin/hive` CLI (`hive init`, `hive new`, `hive run`, `hive status`), `skills/` (shared skills для всех проектов), `logs/` (ротируемые логи всех агентских сессий), `daemon.rb` (Phase 2).
- R15. `hive status` в Phase 2+ агрегирует состояние по всем `~/Dev/*/.hive/stages/` и выдаёт утренний отчёт: какие задачи ждут аппрува, какие упёрлись в STALE, какие завершены, какие PR открыты.

---

## Acceptance Examples

- AE1. **Covers R4, R5.** Given `1-inbox/add-auto-archive/idea.md` свежесоздан, when Ivan вызывает `hive run 1-inbox/add-auto-archive`, then агент пишет `brainstorm.md` с 3–5 вопросами и маркером `<!-- WAITING -->`, завершается без того чтобы двигать папку.
- AE2. **Covers R3, R9.** Given папка `2-brainstorm/refactor-inbox/` с финализированным `brainstorm.md` (маркер `COMPLETE`), when Ivan делает `mv .hive/stages/2-brainstorm/refactor-inbox .hive/stages/3-plan/`, then следующий `hive run` запускает планирование (claude + /ce-plan), пишет `plan.md`, ставит `<!-- WAITING -->`.
- AE3. **Covers R6, R7, R8.** Given в `4-execute/fix-1765/.hive/reviews/ce-review-01.md` 10 findings, Ivan отметил 4 как `[x]`, удалил 3 строки, 3 оставил `[ ]`, when `hive run` триггерит новый pass, then агент применяет только 4 принятых фикса (не трогает 3 оставленные и 3 удалённые), коммитит, и пишет `ce-review-02.md` с новыми findings (если нашлись) или пустым файлом с пометкой «clean pass».
- AE4. **Covers R12, R16.** Given папка `3-plan/add-cache-layer/` с `plan.md` (`COMPLETE`), when Ivan делает `mv` в `4-execute/`, then следующий `hive run` из `~/Dev/writero/` выполняет `git worktree add ~/Dev/writero.worktrees/add-cache-layer -b add-cache-layer`, пишет `.hive/stages/4-execute/add-cache-layer/worktree.yml` с `path: ~/Dev/writero.worktrees/add-cache-layer; branch: add-cache-layer`, коммитит `.hive/` изменения в main (`hive: 4-execute/add-cache-layer worktree spawned [skip ci]`), далее `cd` в worktree и начинает имплементацию по plan.md.
- AE5. **Covers R11.** Given Ivan подключил hive к проекту `~/Dev/seyarabata-new/` с его локальным `CLAUDE.md`, `.claude/skills/`, `.claude/agents/`, when агент запускается на задаче seyarabata-new, then он подхватывает все эти артефакты автоматически без явной конфигурации в hive.

---

## Success Criteria

- Ivan закидывает идею в `1-inbox/` и к утру следующего дня видит в задаче готовый brainstorm + plan + первый execute pass с findings — без того чтобы открывать больше одного терминала в день.
- Время, затраченное на ручное переключение между `/plan`, `/work`, `/ce-review`, `/pr-review-toolkit` и codex /review, падает от десятков минут на задачу до минут суммарно (только триаж findings и движение папок).
- Через 3 месяца Ivan может открыть `6-done/old-task/.hive/` и восстановить полный контекст того, почему задача была сделана именно так, включая brainstorm, plan, все review-paths и принятые/отклонённые findings.
- Любой шаг можно запустить руками (`hive run`) и любую часть артефактов можно отредактировать руками без того чтобы сломать state-машину.
- Сбой в одном проекте не мешает работе остальных 39.

---

## Scope Boundaries

**Deferred for later**
- Автоматическое решение «этот PR готов к мёрджу» — Ivan всегда сам принимает финальное решение merge.
- Кросс-проектные задачи, которые задевают две репозитории одновременно, — в MVP не поддерживаются; заводятся отдельно в каждом проекте.
- Автогенерация новых skills/agents на лету — hive использует то, что Ivan уже положил в `.claude/`.
- Полноценный UI/dashboard поверх hive — достаточно CLI + файлов.

**Outside this product's identity**
- Не строим альтернативу GitHub/Linear/Jira как ticketing-системе. Hive не пытается заменить трекер задач; `1-inbox/` — это быстрый capture, не долгоживущий бэклог.
- Не собираем собственный multi-agent protocol а-ля AutoGen/CrewAI/Swarm. Агенты никогда не общаются друг с другом напрямую; коммуникация всегда через файлы.
- Не делаем web-GUI. Канбан-доски, drag-and-drop карточки — явно отклонены пользователем в пользу редактирования файлов.

---

## Key Decisions

- **Папка-задача вместо одного markdown-файла**: артефакты накапливаются (brainstorm + plan + reviews), их надо различать и искать по паттерну. Один файл разбух бы.
- **Перемещение папки = аппрув**: проще и атомарнее, чем статусы в frontmatter или state-файле. Linux way.
- **Per-project `.hive/` вместо централизованного hive**: routing бесплатный (имя проекта = путь), per-project tooling/`CLAUDE.md`/`.claude/` работают без магии.
- **`.hive/` живёт в main, feature-worktree отдельно**: решили разделить metadata и код. Task-папка с артефактами остаётся в main checkout'е проекта и периодически коммитится прямо в main (`[skip ci]`, сообщения `hive: ...`) — это даёт единое место со статусом всех in-flight задач и git log main как audit trail. Feature-worktree с кодом спавнится в sibling-каталоге `~/Dev/<project>.worktrees/<slug>/`. Агент работает cross-path: читает/пишет артефакты в main, правит код в worktree.
- **`claude -p` subprocess вместо Claude Agent SDK или Hermes**: Claude Code сам умеет подхватывать `.claude/` convention из cwd, кастомный harness не даёт выигрыша.
- **Polling + fswatch hybrid вместо чистого cron**: Kieran сидит на чистом cron с лагом 60 с, что раздражает в интерактивных брейнштормах. Hybrid даёт отзывчивость + robustность.
- **MVP без демона, на одном проекте**: Kieran’s «build, use, trust, then delegate». Демон до проверки стадий размножит ошибки на 40 проектов.
- **Чекбоксы как протокол accept/reject**: универсально для всех интерактивных фаз (Q&A, findings triage, plan review), читаемо глазами, git-friendly.

---

## Dependencies / Assumptions

- Claude Code CLI (`claude -p`) стабильно работает в headless-режиме и не требует интерактивного TTY. **Не верифицировано** для конкретной версии, которую использует Ivan; проверить при старте Phase 1.
- Каждый целевой проект уже имеет осмысленный `CLAUDE.md` и, желательно, `.claude/skills/`, `.claude/agents/`. Для проектов без этого hive не даст преимущества, пока Ivan не доведёт их до «папки-агента» в смысле Kieran.
- `gh` CLI установлен и авторизован для всех подключённых проектов (для `gh pr create` в 5-pr и `gh api` в Phase 3).
- QMD уже проиндексировал проекты (коллекции `seyarabata-new`, `writero`, `appcrawl`, `curriculum`, `topgreendeals`, etc. подтверждены); hive будет дописывать в новые коллекции или существующие `-learnings`.
- Feature-worktrees можно безопасно создавать в sibling-каталоге `~/Dev/<project>.worktrees/` без конфликта с основным клоном. Git 2.5+ поддерживает это из коробки. **Не верифицировано** для writero — проверить при `hive init`.
- Pilot-проект для Phase 1 — **writero** (Rails, активный поток задач, уже в QMD-коллекции). Hive-init делается именно там; остальные 39 проектов подключаются позже.
- `.hive/` коммитится в main проекта напрямую. В writero это не создаёт конфликт с текущим flow — никакой защищённой main-ветки с обязательным PR-review для `.hive/`-коммитов нет. **Проверить** при старте Phase 1, что у writero нет branch-protection rules, блокирующих прямые push в main.

---

## Future Extensions (Phase 3+)

Зафиксировано для памяти, не в MVP. Все три категории **не меняют** базовый инвариант (filesystem = source of truth, маркеры = state, перемещение папки = аппрув) и встают поверх существующей архитектуры.

### I/O-адаптеры

Адаптеры, которые читают и пишут ту же state-машину, что и CLI. Не новая логика, новые интерфейсы.

- **Telegram bot (двунаправленный).** Long-polling процесс на локалке. Outbound: post-transition hook в демоне слушает изменения маркеров (`COMPLETE`/`WAITING`/`ERROR`/`EXECUTE_STALE`) и шлёт уведомление с кратким preview артефакта и кнопками «Approve → next» / «Reject → back» / «View full». Inbound: команды `/approve <task>`, `/reject <task>`, `/status`, `/idea <project> <text>` мапятся на те же filesystem-операции, что и CLI. Конфиг в `~/Dev/hive/config.yml`: `bot_token`, `chat_id` whitelist, какие события нотифай.
- **`hive new <project> '<text>'` CLI.** Чистый scaffolder: создаёт `~/Dev/<project>/.hive/stages/1-inbox/<auto-slug>/idea.md` с переданным текстом. Slug — kebab-case первых 5 слов + timestamp. Стоит добавить уже в Phase 1 ради эргономики capture.
- **Desktop notifications / email / Slack** — по тому же паттерну, что Telegram: post-transition hook + событийная подписка в `config.yml`. Каждый новый канал = один адаптер, без изменений в ядре.

**Landmines:**
- Удалённый Telegram-бот = remote execution. Whitelist `chat_id` обязателен, секреты через env vars.
- Одновременный аппрув с ноута и с телефона → `.hive/.lock` и atomic `mv`.
- Для 24/7 доступа нужен cloud-relay (Tailscale или ngrok); long-polling на локалке — дешёвое 80%-решение.

### Observability probes (второй трек `.hive/reports/`)

Это **единственное расширение, которое добавляет новую абстракцию.** Формулировка: помимо event-driven `stages/` трека, который меняет мир, есть schedule-driven `reports/` трек, который читает мир и пишет digest'ы. Это ровно паттерн `~/cora-agent/` у Kieran Klaassen, встроенный внутрь каждого проекта:

```
~/Dev/<project>/.hive/
  stages/                         # трек 1: code-change pipeline (MVP)
  reports/                        # трек 2: observability probes (Phase 3+)
    honeybadger-errors/
      config.yml                  # cron, MCP, prompt template
      runs/
        2026-04-24T08:00.md
        2026-04-24T12:00.md
      latest.md -> symlink
    ahrefs-seo-weekly/
      config.yml
      runs/...
```

Каждый probe конфигурируется через `config.yml` c полями `schedule` (cron), `prompt_template`, `mcp_servers`, `notify_on_change`, `retention.keep_runs`. Тот же Phase 2 демон получает дополнительный cron-loop и запускает `claude -p` в папке проекта с подгруженным prompt'ом и доступом к указанным MCP.

**Meta-digest** в `~/Dev/hive/morning-digest/` — отдельный probe, который читает все `latest.md` из `~/Dev/*/.hive/reports/*/` и синтезирует 3–5-пунктовую сводку по всем проектам. Отправляется в Telegram в 8 утра.

**Landmines probes:**
- Token-cost взрывается: 40 проектов × 3 probe × 6 runs/день = **720 LLM-запусков в сутки**. Нужно (а) включать probes только где реально ценно; (б) `max_runs_per_day` cap в config; (в) дедупликация — перед запуском LLM посчитать hash raw MCP-ответа и сравнить с предыдущим run'ом, пропустить если не изменилось.
- MCP-auth: токены honeybadger/ahrefs надо пошарить между интерактивной Claude Code сессией и фоновым демоном, либо завести отдельные.
- Silent failures: probe стабильно падает → ты об этом не узнаёшь. Alert если N подряд runs зафейлились.

### Cross-cutting: уже запланировано

- **`hive status` cross-project overview** — R15 в MVP/Phase 2, агрегирует все `~/Dev/*/.hive/stages/*/`. Priority signals (⚠ stale, ⏸ waiting for you, 🤖 in progress, ✓ recently completed) стоит докрутить, но не меняют архитектуру.

---

## Outstanding Questions

### Resolve Before Planning

_(Пусто — pilot-проект и git-политика закреплены в Dependencies / Key Decisions.)_

### Deferred to Planning

- [Affects R4, R9][Technical] Точный формат CLI: `hive run <path>`, `hive run <project>/<slug>`, или auto-detect первую папку с отсутствующим маркером `COMPLETE`?
- [Affects R10][Technical] Какой язык для демона: Ruby (как у Kieran), Python, Go? Влияет на lock-файлы, fswatch bindings, распаковку stream-json от `claude -p`.
- [Affects R11][Needs research] Какой `--permission-mode` у `claude -p` безопасно дефолтить для автономного execute (acceptEdits? plan-mode? что-то промежуточное)?
- [Affects R13][Needs research] Формат экспорта `.hive/*` в QMD: сохраняем как есть (set of markdown), конвертим в один consolidated doc, или делаем summary через LLM на этапе архивации?
- [Affects R6][Technical] Как запустить Codex /review локально vs. только на открытом PR? Текущее поведение Codex — PR-only; если так, pr-review/codex переезжают в 5-pr/ полностью.
- [Affects R4][Technical] Защита от конкурентного запуска двух `hive run` на одной папке в MVP (без демона). Lock-файл достаточен, или нужна advisory lock типа flock?
- [Affects R16][Technical] Как именно исключить `.hive/` из feature-worktree? Варианты: `.gitattributes` с `export-ignore`/`skip-worktree`, `sparse-checkout` при `git worktree add`, либо просто `rm -rf .hive/` внутри worktree после создания. Надо проверить что удобнее и не рушит git-состояние main.
- [Affects R16][Technical] Частота hive-коммитов в main: после каждого `hive run` (каждая стадия = 1 коммит), или батч через debounce? Если агент за минуту прописывает 5 файлов, хочется один коммит а не 5.
- [Affects R16][User decision, needs research] Что делать если у проекта **есть** branch-protection на main (нельзя прямой push)? Варианты: (а) выключить hive для таких проектов; (б) hive-коммиты через отдельный `hive/state`-бранч с auto-PR; (в) всё-таки in-worktree `.hive/` для таких случаев как fallback.

---

## Next Steps

`-> /ce-plan` для разбивки Phase 1 MVP на конкретные задачи и файлы. Pilot-проект writero, `.hive/` в main проекта с прямыми коммитами, feature-worktrees в `~/Dev/writero.worktrees/`.
