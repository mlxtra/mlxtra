# MLXHub UI Ideas

This note captures nice-to-have UI and interaction improvements to implement over time. It is intentionally a backlog, not a commitment to implement everything immediately.

## Recommended Order

1. Animated generating composer
2. Drag-and-drop and pasted image attachments
3. Tool call status cards
4. Rich media result cards
5. Response hover actions
6. Command palette

## Ideas

### Animated Generating Composer

Add an animated soft multicolor border/glow around the composer while the assistant is responding. Show a muted `Responding...` placeholder and a square stop button wired to `ChatViewModel.cancelGeneration()`.

Likely implementation point: `ComposerView` in `MLXHub/Views/WelcomeView.swift`, because it is used by both the welcome screen and `ChatView`.

### Streaming Message Polish

Add a subtle animated caret, shimmer, or small status cue at the end of the currently streaming assistant message. Keep the animation restrained so long responses remain readable.

### Tool Call Status Cards

Show compact status cards or pills when tools are running, such as `Generating image...`, `Creating music...`, or `Searching web...`. Transition the card into the resulting media or completion state when the tool finishes.

### Model Loading Progress Surface

Improve the existing model loading UI with model name, icon/type, status text, and a subtle progress shimmer. Consider retry/cancel affordances where the backend supports them.

### Attachment Tray Improvements

Improve image attachment handling with drag-and-drop, pasted image support, hover preview, and a file count chip when multiple images are attached.

### Empty-State Prompt Gallery

Add high-quality starter prompt chips on new chats, grouped by mode: Ask, Vision, Image, Speech, and Music. Chips should fill the composer and focus it, not necessarily send immediately.

### Response Actions Toolbar

Add a small hover toolbar for assistant messages with actions such as Copy, Regenerate, Continue, Read aloud, and Save output.

### Rich Media Result Cards

Use richer result cards for generated outputs:

- Images: preview, open, reveal, copy
- Audio/speech: playback card and metadata
- Music: playback card, duration, prompt summary, reveal file

### Command Palette

Add a `Command-K` palette for new chat, switch model, select tool, open settings, search chats, and clear current chat.

### In-Chat Search

Add search within the current conversation with highlighted matches and next/previous navigation.

### Per-Message Model And Tool Badges

Show small badges on assistant messages or tool results indicating which model/tool produced the output, such as `Qwen`, `FLUX.2`, `ACE-Step`, or `Web`.

### Smart Scroll Behavior

While streaming, auto-scroll only if the user is already near the bottom. If the user scrolls upward, pause auto-scroll and show a `Jump to latest` button.

### Keyboard Polish

Add shortcuts such as:

- `Esc` to stop generation
- `Command-K` to open the command palette
- `Command-L` to focus the composer
- Up arrow to edit the last user message when the composer is empty

### Inline Editing And Retry

Let users edit a previous user message and regenerate from that point. This is larger than visual polish because it affects conversation state and retry behavior.

### Conversation Title Animation

When the first message is sent, transition from the default chat title to the derived/generated title with a subtle fade.

### Subtle Message Entrance Animations

Fade or slide new messages in slightly. Keep transitions layout-stable and avoid interfering with streaming updates.

### Better Typing Indicator

Replace or refine the current three-dot indicator with a small thinking/status pill that can optionally include the selected model name.

### Glass Composer Focus State

Add a mild focused border/glow for the composer when editing. During generation, switch to the animated gradient treatment.

### Sidebar Visual Hierarchy

Improve chat list rows with an active chat indicator, timestamp, one-line preview, pinned chats, and compact hover actions.

### Settings Health Check

Add a runtime/model status panel that checks Python runtime presence, downloaded models, bridge health, Metal settings, and optionally runs a small bridge test.
