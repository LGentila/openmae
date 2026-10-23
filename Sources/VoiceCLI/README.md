# voice-cli

`voice-cli` uses the same engine and the same models as the app, without any interface: it downloads the models,
measures the engine and runs the benchmarks. The commands below run from the root of the repository, once it is built
(see [Building from source](../../README.md#building-from-source)).

Download the models of this Mac's tier (or of `--tier minimum|standard|comfort|max`):

```bash
.build/xcode/Build/Products/Release/voice-cli download
```

Check every downloaded file against its SHA-256 (about one second per GB):

```bash
.build/xcode/Build/Products/Release/voice-cli verify
```

Measure the engine with recorded speech, played in real time as a microphone would. First generate the test
phrases with macOS's built-in voices:

```bash
zsh scripts/make-test-audio.sh
```

A conversation, with the latency of each stage:

```bash
.build/xcode/Build/Products/Release/voice-cli conversation measurements/audio/0*.wav
```

`--gaps 30-150` leaves between two turns that many seconds of silence (drawn in the range, the same at every run), as
when the user asks for something now and then. With `VOICE_DEBUG=1 VOICE_DEBUG_MEMORY=1`, the log then says, before each
request, how much of the weights, of the conversation's memory (the cache and its copies) and of the process's memory
macOS had compressed or written to swap, and how much MLX kept of its free buffers; then how long the request took to
read its new tokens (“LLM: prefill”).

Interruptions (speaking over the assistant):

```bash
.build/xcode/Build/Products/Release/voice-cli interruption measurements/audio/10-histoire.wav measurements/audio/11-stop.wav
```

What it takes to interrupt Maé depends on the device that has the conversation, since her echo is not as loud on each
one (`BargeInProfile`): on the Mac, a voice over hers must reach -38 dB for 224 ms; on an iPhone, -30 dB for 288 ms (an
iPad keeps the Mac's values for now). `--barge-in iphone` measures the interruptions with the iPhone's. With
`VOICE_DEBUG=1`, the app's log says how each voice heard over hers was judged ("speech started (level … dB, over the
assistant…)" or "ignored while the assistant talks…") and, after each answer, what was heard over her voice: how many
bursts, the longest, the loudest. To try other values on an iPhone without building the app again, launch it with
`VOICE_BARGE_IN_IPHONE_DB` (the level) and `VOICE_BARGE_IN_IPHONE_MS` (the duration):

```bash
open --env VOICE_DEBUG=1 --env VOICE_BARGE_IN_IPHONE_DB=-28 --env VOICE_BARGE_IN_IPHONE_MS=320 --stderr /tmp/openmae.log .build/app/Build/Products/Release/OpenMae.app
```

Memory over time (here 10 minutes):

```bash
.build/xcode/Build/Products/Release/voice-cli endurance --minutes 10 measurements/audio/0*.wav
```

`--actions` puts the actions in the model's instructions, as in the app when they are on (none is carried out, a call
is declined); with `--new-conversation-every 4`, a new conversation starts every four turns, as with "New
conversation" in the app, and the time it takes is shown. `--wake-word` only answers the recordings that start with
« OK Maé », as the app's wake-word mode; add `--follow-up 0` so that every recording needs the phrase (no seconds of
attention after an answer). `--no-voice-restart` keeps the voice going when its opening stays near-silent (the app
starts it again after 1.2 s of near-silence), and `--racing-voices 2` starts each answer with two voices at once, the
first one audible saying it (off in the app: 1.2 GB more memory). The words the user says so far are printed while
each recording plays, as the app shows them; `--no-partials` turns that off, for comparison. `--talk-key` holds the
talk key while each recording plays and releases it `--release-after` seconds later (0.25 by default), as ⌥ Space.

The voice alone: how long it takes to make its first audible sound on typical first sentences, and the near-silence it
produces before (Pocket TTS opens each sentence with a breath of random length). `--parallel 2` has two voices speak
each sentence at once, the first audible one counting (as `--racing-voices 2` in a conversation); `--with-llm` has the
language model write an answer meanwhile, paused once its first sentence is written, as in a turn:

```bash
.build/xcode/Build/Products/Release/voice-cli voice-onset --repeats 5 --parallel 2
```

The voice's pace through long answers, without the pipeline: five sentences said in one utterance, answer after
answer, and the time per 80 ms frame by second since each answer's first frame. `--with-llm` loads the language model
too (its memory is taken as in the app), and `--model-writes 120` has it write that many pieces at the start of each
answer; `--fingerprint` prints a fingerprint of two sentences said with a fixed seed, the same in two builds that make
the same sound:

```bash
.build/xcode/Build/Products/Release/voice-cli voice-pace --with-llm --repeats 5
```

With `VOICE_DEBUG=1`, every engine command also logs, for each sentence the voice says, how long its first frame took,
how many near-silent frames came before the first audible one and how fast the frames came; and at the end of each
utterance, how fast all its frames came, its slowest frame, and how many other utterances of the voice ran at the same
time.

An announcement cut by a home station's drop (the iPad unplugged 0.6 s into the chime), said again at once on the
Mac, as the app does; each try reports the pace of every utterance of the voice, when the Mac's chime rang, and the
gaps in the Mac's sound after it. `--mute-first` takes the Mac's first utterance of it for near-silence, so that the
voice would start it again after 1.2 s of its audio (an announcement said again from its recording no longer uses the
voice); `--mute-station` does the same on the station, whose voice then starts again just after the drop. `--on-mac`
has the announcement said on the Mac from the start, by the voice (a timer that rings with no home station);
`--chime-wait` sets how long the chime waits at most for the voice's first sound (0.3 s in the app; 0: at once):

```bash
.build/xcode/Build/Products/Release/voice-cli announce-drop --repeats 6 --mute-station
.build/xcode/Build/Products/Release/voice-cli announce-drop --repeats 10 --on-mac --mute-first
```

Check that the language model picks the right action, with the right date. Text only, nothing is created: the
French requests of `Tests/Fixtures/actions-fr.json` (actions, and traps that only look like one) are sent at a
fixed reference time, and the report gives the right-tool rate, the dates, false triggers and the time to a
complete call:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench
```

The same with the tools that hand tasks to Claude Code (requests to hand over, questions about programming
that must not be, and questions about a task already handed over). Their calls are checked by the app's own
delegation tools, which know the tasks handed over earlier in the case and a finished task of an earlier launch
(`earlierTasks`): a follow-up that names no known task is refused, and the model's second try counts, as in the app:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/agents-fr.json
```

With `--no-actions`, the actions are left out (their tools, their part of the prompt, their example exchanges), as the
app has Claude Code, the web search or the built-in sources when the actions are off: the delegation's part of the
prompt is then the one that says on its own how to call its tool, with an example call. A request for an action then
expects no call, and a hand-over written after words of the model's own counts as none: the app leaves it out, saying
nothing of it (the report lists them). `--agents-addendum <file>` replaces the delegation's part, to try another wording
without rebuilding:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/agents-fr.json --no-actions
```

Searching the internet: requests that need a search, requests that do not (traps included), research for an agent,
and requests that follow a search whose results did not answer (the user insists or asks for other sites: a new
search is expected, with keywords of its own; or asks for nothing new). The model sums up the results recorded for
each request in the corpus, as the app would have it do, and the report gives the right decisions, the searches made
by mistake, the keywords and what the summaries said:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/web-fr.json
```

With `--searxng <address>`, the searches are made for real on that SearXNG, with the model's own keywords; `--web`
offers the search tool with the other corpora too, to check that it does not change their results;
`--web-addendum <file>` replaces the search's part of the system prompt, to try another wording without rebuilding.
`--compare-beginnings` generates nothing: it computes the beginning of the conversations (the system prompt with its
tools) as the app does (in float32, then rounded: the same state at load and after a tools change), then in bfloat16 as
it was computed before and with every weight in float32 as a reference, compares the model's memory after each, and
gives every request's chance of a call at its first token from each, read as the app reads it (from the state at load,
the same as `--watch-calls`; a request whose decision moves with mere rounding is one the model hesitates on).
`--compare-requests` generates nothing either: from the beginning the app keeps, it reads each request's first token
computed as the app computes it (its new tokens in float32, the same as `--watch-calls`), as it was computed before (in
bfloat16), with Gemma 4 26B also with its experts' products in bfloat16 rather than float32, and for a request with
earlier exchanges with those computed first on their own (as the history computed ahead, or in one pass), against the
same float32 reference. `--bfloat16-prompts` (also for `cache-check`) computes the requests' new tokens and the history
in bfloat16, as the app did before, and `--bfloat16-experts` computes Gemma 4 26B's experts' products in bfloat16 while
the rest of them is computed in float32, to compare in one build. One
search, made as the app makes it (the password, if any, in `SEARXNG_PASSWORD`):

```bash
.build/xcode/Build/Products/Release/voice-cli web-search --searxng https://search.example.org horaires piscine Pontoise
```

The weather, rates and travel times: requests for each, requests that must not use them (general knowledge, small
talk, questions for the web search, actions), with the services' answers recorded so that it runs offline;
`--live-sources` asks the real services instead (timed; “here” is the corpus's place) and `--record-sources file.json`
writes what they answered; `--sources` offers these tools with the other corpora too:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/sources-fr.json
```

The news of received information (« Quoi de neuf ? », the tool `lire_nouvelles`, offered while a source exists):
requests for the user's news, requests that must not use it (small talk, the news of the world, which is the web
search's, actions with close words); `--news` offers it with the other corpora too, to check that it does not change
their results:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/news-fr.json
```

Short conversations, as the app has them: the dialogues of `Tests/Fixtures/dialogues-fr.json` (here, a request for a
moment already gone, then the user's new moment; or a request whose call the app refuses for the model's second try,
then the user's answer to the app's question) are sent turn after turn, text only and with nothing created: each call
goes through the app's checks and second try, and is carried out on a calendar kept in memory that answers as the app
would. The model samples its answers, so each dialogue runs several times, and the report says what the model did at
each turn, how many answers said nothing to the user and how often the item the user wanted was saved (for a last
request that asks for what is already so, as putting a meeting in the calendar it is in: how often nothing was done,
nor said done):

```bash
.build/xcode/Build/Products/Release/voice-cli dialogue-bench --repeats 10
```

The same with Claude Code switched on (`Tests/Fixtures/agents-dialogues-fr.json`): a task is handed over, read back and
confirmed as in the app, then ended by the dialogue (`[tâche terminée]`), as when the agent is done; the user then asks
for the same work again (it must be handed over again, or the answer must say it is over, never that it still runs), or
for something else (an appointment, saved without bringing the task up):

```bash
.build/xcode/Build/Products/Release/voice-cli dialogue-bench --corpus Tests/Fixtures/agents-dialogues-fr.json --repeats 10
```

The memory's tool (`memoire`: remember, forget an entry, erase everything): requests to remember, forget and erase
everything, and above all traps — small talk, general knowledge, a real web search, an action, and facts said without
asking Maé to remember them, which must not be remembered; `--memory` offers the tool with the other corpora too (with
an empty sheet). Its journal of past exchanges (searching them, erasing a period of them) is offered only as the app
offers it, which it does not in this version: `--journal` offers it; without it, the requests that need it are left out
of the score and reported apart. The same goes for `dialogue-bench` and `cache-check`:

```bash
.build/xcode/Build/Products/Release/voice-cli actions-bench --corpus Tests/Fixtures/memory-actions-fr.json
```

The memory's history search, without a model: recall@4 and MRR by kind of query (the exchange's own words, paraphrases,
a period, speech-to-text mistakes, traps) on a synthetic corpus, the same with the French sentence embedding macOS
already has (to decide on searching by meaning), then the search's speed and the database's size at 20,000 exchanges:

```bash
.build/xcode/Build/Products/Release/voice-cli memory-bench
```

The same journal with the model, switched on for the run only (in a temporary folder, never the user's): spoken
questions about a past conversation — about what the user said or what Maé said (a recipe, an address, a
recommendation), with a period or without, with the exchange's words or other words — and requests that must not
search. Per kind of request: how often the model searched the journal, how often the search found the exchange, and how
often the answer used it; and how often it searched when nothing asked for it:

```bash
.build/xcode/Build/Products/Release/voice-cli journal-bench --tier standard --repeats 3
```

How much of each request the language model finds in its memory (its KV cache), in the sequences of requests the app
sends: plain turns, an action, two actions in one request, what the app says on its own (an announcement, which the
model computes in the background once said, and a request sent meanwhile), a refused call and its second try, a long
result summed up (as after a web search), a turn dropped after a second try, a speculative or interrupted answer, an
answer in paragraphs, a speculative answer abandoned after an answer cut off, the tools changing, the history
shortened, a new conversation (with `--memory`: the memory's sheet unchanged, then changed). Text only, nothing is
created; run it again after any change to `MLXChatModel`. With `VOICE_DEBUG=1`, it also shows where each request stops
matching that memory, and what differs. `--cut-off ahead` or `--cut-off after-user-words` puts the note of an answer cut
off where another tier does (see below):

```bash
.build/xcode/Build/Products/Release/voice-cli cache-check
```

How long the language model takes to read a request's new tokens, by their number: after a conversation of about 1,500
tokens, the first N tokens of the next request are read as a request reads them (in float32, up to the answer's first
token), for N from `--from` to `--to`, `--runs` times each. Gemma 4 26B's experts pad their rows to the count from which
MLX computes them in blocks (`ReadingExperts` in `MLXChatModel.swift`); `--compare-padding` reads each N never padded,
padded whenever their rows are sorted and as in the app, one right after the other, and `--unpadded-experts` (also for
`cache-check`) never pads them, as before:

```bash
.build/xcode/Build/Products/Release/voice-cli read-sizes --from 32 --to 96 --runs 5 --compare-padding
```

Answers cut off one after the other, as when the user speaks over Maé: the dialogues of `Tests/Fixtures/cut-offs-fr.json`
(twelve answers cut off in a row; answers cut early, then what a user who did not hear their end would ask), text only.
Each answer cut off goes into the history as the app records it on the tier: what the voice had been given, then a note
saying that the user cut Maé off, which Gemma 4 26B reads ahead (a message of its own right after the answer, computed
while the user still speaks) and E4B and E2B after the user's words, in their next message. The report prints every
answer, and counts those in which the model wrote the mark of a cut itself (« […] », which the history once ended such
answers with: the model copied it, dozens in a row, and the voice read them), copied the note, or went round in circles
and was stopped. `--cut-off ahead` or `--cut-off after-user-words` puts the note where another tier does; for
comparison, `--cut-off marker` records the answers cut off as the app did before (« […] » at their end),
`--cut-off none` without saying anything:

```bash
.build/xcode/Build/Products/Release/voice-cli cut-off-bench --repeats 10
```

Answers cut by a drop (the iPhone that has the conversation went out of reach in the middle of an answer and was not
back in time to hear the rest): the dialogues of `Tests/Fixtures/drops-fr.json`, three « Raconte-moi … » answers cut
after their first piece, with or without a question between them, then a fourth heard to its end. Each answer cut by
the drop goes into the history as the app records it: as the model wrote it, then a note saying that the link dropped
and the user heard only its beginning, where the tier puts the note of an answer cut off. The report counts, per turn,
the answers heard to their end that hold a single whole sentence. For comparison, `--drop heard` keeps only what the
device heard, then the note, `--drop cut-off` what it heard as an answer the user cut off (as the app did before),
`--drop none` what it heard without a note, `--drop whole` as if there had been no drop:

```bash
.build/xcode/Build/Products/Release/voice-cli cut-off-bench --corpus Tests/Fixtures/drops-fr.json --actions
```

Words the voice is given misspelled (« constru-ée » for « construite », « Aujourd'elle »): the requests for a story of
`Tests/Fixtures/stories-fr.json`, each answered `--repeats` times (20 by default) in a new conversation, text only.
Each answer goes to the voice as in the app, and every token the model drew is kept with the chance the model gave it
and the tokens it found likeliest there. A hyphenated word the system's French spell checker does not know is a split
word, and every word it does not know is reported too: the report prints each one with the tokens the model drew for
it, and counts per request the answers holding one, in what the model wrote and in what the voice is given.
`--request "…"` asks that instead of the corpus; `--actions`, `--agents`, `--web`, `--sources`, `--news` and `--memory`
put those tools in the prompt as in the app; `--hold 1` holds the model a second after each piece, as while the voice
needs the GPU; `--reread` reads each answer again in one pass, as a prompt is read, in the model's own type and in
float32, and shows the chances the model gives each such word's tokens then; `--min-p` draws the tokens with another
min-p than the app's, and `--bfloat16-prompts` computes the requests in bfloat16, to compare in one build:

```bash
.build/xcode/Build/Products/Release/voice-cli story-bench --actions --agents --web --sources --memory --reread
```

Hand a task to Claude Code the way the app does, without the app or a language model (it uses the Claude Code
signed in on this Mac; `--check` only says whether it is installed and signed in):

```bash
.build/xcode/Build/Products/Release/voice-cli delegate --instruction "Crée un fichier bonjour.txt qui dit bonjour."
```

To move a model to another version (a deliberate change, to be measured again): edit its `revision` in
`Sources/VoiceCore/ModelCatalog.swift`, then regenerate the list of its files, sizes and SHA-256 from Hugging
Face:

```bash
.build/xcode/Build/Products/Release/voice-cli catalog
```
