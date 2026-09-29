import 'package:flutter/material.dart';

/// Lets a tab body contribute a floating action button to the shell.
///
/// `HomeShell` owns the Scaffold's single `floatingActionButton` slot and fills
/// it with the SARA mark. A tab that also needs a floating action (Messages has
/// "new chat / channel / group") cannot place one in its own layout: the
/// shell's button floats above the entire body, so it renders on top of
/// whatever the body drew and intercepts its taps.
///
/// Instead of guessing offsets, the body publishes its button here and the shell
/// stacks the two. That makes overlap structurally impossible rather than merely
/// unlikely, and it keeps a single Scaffold so the bottom bar and the safe area
/// are still handled in one place.
class HostFabScope extends InheritedWidget {
  const HostFabScope({super.key, required this.notifier, required super.child});

  /// The tab body's publishable button. Null means "this tab has no FAB".
  final ValueNotifier<Widget?> notifier;

  /// Notifier of the most recently mounted scope, or a detached fallback.
  ///
  /// The fallback keeps a screen usable outside the shell (a pushed route, a
  /// widget test, a preview): its button simply is not hosted rather than the
  /// build throwing.
  static final ValueNotifier<Widget?> detached = ValueNotifier<Widget?>(null);
  static ValueNotifier<Widget?> _active = detached;

  /// The notifier the shell is currently listening to.
  static ValueNotifier<Widget?> get current => _active;

  /// Points the scope at this shell instance. Called by `HomeShell`.
  static void attach(ValueNotifier<Widget?> notifier) => _active = notifier;

  /// Restores the detached fallback. Called by `HomeShell` on dispose so a
  /// disposed shell can never keep being written to.
  static void detach() => _active = detached;

  static HostFabScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HostFabScope>();

  @override
  bool updateShouldNotify(HostFabScope oldWidget) =>
      oldWidget.notifier != notifier;

  /// Element that keeps [current] pointing at the innermost live scope.
  @override
  InheritedElement createElement() => _AttachingHostFabScopeElement(this);
}

/// Element that points [HostFabScope.current] at its scope's slot on mount and
/// restores the detached fallback on unmount.
///
/// This keeps the static always pointing at the innermost live scope, so a
/// screen that publishes from inside the tree writes to the right shell even
/// when several scopes exist (a test harness inside a real shell, say).
class _AttachingHostFabScopeElement extends InheritedElement {
  _AttachingHostFabScopeElement(HostFabScope super.widget);

  @override
  HostFabScope get widget => super.widget as HostFabScope;

  ValueNotifier<Widget?>? _previous;

  @override
  void mount(Element? parent, Object? newSlot) {
    super.mount(parent, newSlot);
    // Remember the enclosing scope so unmount restores it rather than
    // detaching outright, keeping the stack correct for nested scopes.
    _previous = HostFabScope.current == widget.notifier
        ? null
        : HostFabScope.current;
    HostFabScope.attach(widget.notifier);
  }

  @override
  void unmount() {
    if (HostFabScope.current == widget.notifier) {
      HostFabScope.attach(_previous ?? HostFabScope.detached);
    }
    _previous = null;
    super.unmount();
  }
}

/// Publishes a FAB into [HostFabScope] for as long as the widget is mounted.
///
/// The button is cleared on dispose, so a button belonging to a screen the user
/// has navigated away from can never be left floating over unrelated content.
class HostFabPublisher extends StatefulWidget {
  const HostFabPublisher({super.key, required this.builder});

  /// Builds the button, or returns null when this screen has nothing to float.
  final Widget? Function(BuildContext context) builder;

  @override
  State<HostFabPublisher> createState() => _HostFabPublisherState();
}

class _HostFabPublisherState extends State<HostFabPublisher> {
  /// The slot this publisher wrote to, so dispose only clears its own value.
  ValueNotifier<Widget?>? _slot;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Resolve the slot from the tree rather than from a global, so a publisher
    // always writes to the scope it is actually inside. Falls back to the
    // active notifier when used standalone (preview / test).
    final slot =
        HostFabScope.of(context)?.notifier ?? HostFabScope.current;
    _slot = slot;
    HostFabScope.attach(slot);
    _publish();
  }

  @override
  void didUpdateWidget(HostFabPublisher oldWidget) {
    super.didUpdateWidget(oldWidget);
    _publish();
  }

  void _publish() {
    // Deferred: assigning during build would notify the shell mid-build and
    // trip Flutter's "setState during build" guard.
    final slot = _slot ?? HostFabScope.current;
    final next = widget.builder(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || slot.value == next) return;
      slot.value = next;
    });
  }

  @override
  void dispose() {
    _slot?.value = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
