import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../providers/app_providers.dart';
import '../utils/debug_logger.dart';
import '../../features/auth/providers/unified_auth_providers.dart';
import 'app_intents_service.dart';
import 'navigation_service.dart';

part 'deep_link_service.g.dart';

/// Deep link action types.
class DeepLinkActions {
  static const String connect = 'connect';
  static const String chat = 'chat';
}

/// Stores a pending server URL from a deep link for the server connection page.
@Riverpod(keepAlive: true)
class PendingDeepLinkServer extends _$PendingDeepLinkServer {
  @override
  String? build() => null;

  void set(String? url) => state = url;

  void clear() => state = null;
}

/// Handles deep links for connecting to Open-WebUI servers.
///
/// Supported URL formats:
/// - `conduit://connect?url=https://my-openwebui.com`
///   Opens the server connection page with the URL prefilled.
///
/// - `conduit://chat?server=https://my-openwebui.com&prompt=Hello`
///   If already connected to the specified server, opens chat with optional prompt.
///   If not connected, opens server connection page with URL prefilled.
@Riverpod(keepAlive: true)
class DeepLinkCoordinator extends _$DeepLinkCoordinator {
  late final AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  @override
  FutureOr<void> build() async {
    if (kIsWeb) return;
    if (!Platform.isIOS && !Platform.isAndroid) return;

    _appLinks = AppLinks();
    await _initialize();

    ref.onDispose(() {
      _linkSubscription?.cancel();
    });
  }

  Future<void> _initialize() async {
    try {
      // Handle link that launched the app (cold start)
      final initialUri = await _appLinks.getInitialLink();
      if (initialUri != null) {
        DebugLogger.log(
          'Deep link: Initial launch URI: $initialUri',
          scope: 'deeplink',
        );
        // Process after a delay to allow app initialization
        _processDeepLinkAfterStartup(initialUri);
      }

      // Listen for links while app is running (warm start)
      _linkSubscription = _appLinks.uriLinkStream.listen(
        _handleDeepLink,
        onError: (error) {
          DebugLogger.error(
            'deep-link-stream',
            scope: 'deeplink',
            error: error,
          );
        },
      );

      DebugLogger.log('Deep link service initialized', scope: 'deeplink');
    } catch (error, stackTrace) {
      DebugLogger.error(
        'deep-link-init',
        scope: 'deeplink',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Process deep link after app startup, waiting for router to be ready.
  Future<void> _processDeepLinkAfterStartup(Uri uri) async {
    // Wait for router to be attached
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (NavigationService.currentRoute != null) {
        DebugLogger.log(
          'Deep link: Router ready, processing initial link',
          scope: 'deeplink',
        );
        break;
      }
    }

    if (NavigationService.currentRoute == null) {
      DebugLogger.log(
        'Deep link: Timeout waiting for router',
        scope: 'deeplink',
      );
      return;
    }

    await _handleDeepLink(uri);
  }

  Future<void> _handleDeepLink(Uri uri) async {
    DebugLogger.log('Deep link received: $uri', scope: 'deeplink');

    // Only handle conduit:// scheme
    if (uri.scheme != 'conduit') {
      DebugLogger.log(
        'Deep link: Ignoring non-conduit scheme: ${uri.scheme}',
        scope: 'deeplink',
      );
      return;
    }

    final action = uri.host.isNotEmpty
        ? uri.host
        : uri.pathSegments.firstOrNull;

    if (action == null || action.isEmpty) {
      DebugLogger.log('Deep link: No action specified', scope: 'deeplink');
      return;
    }

    switch (action) {
      case DeepLinkActions.connect:
        await _handleConnectAction(uri);
        break;
      case DeepLinkActions.chat:
        await _handleChatAction(uri);
        break;
      default:
        DebugLogger.log(
          'Deep link: Unknown action: $action',
          scope: 'deeplink',
        );
    }
  }

  /// Handle `conduit://connect?url=https://...`
  Future<void> _handleConnectAction(Uri uri) async {
    final serverUrl = uri.queryParameters['url'];
    if (serverUrl == null || serverUrl.isEmpty) {
      DebugLogger.log(
        'Deep link: connect action missing url parameter',
        scope: 'deeplink',
      );
      return;
    }

    DebugLogger.log(
      'Deep link: Connect to server: $serverUrl',
      scope: 'deeplink',
    );

    // Store the pending server URL for the connection page
    ref.read(pendingDeepLinkServerProvider.notifier).set(serverUrl);

    // Navigate to server connection page
    NavigationService.navigateToServerConnection();
  }

  /// Handle `conduit://chat?server=https://...&prompt=Hello`
  Future<void> _handleChatAction(Uri uri) async {
    final serverUrl = uri.queryParameters['server'];
    final prompt = uri.queryParameters['prompt'];

    if (serverUrl == null || serverUrl.isEmpty) {
      DebugLogger.log(
        'Deep link: chat action missing server parameter',
        scope: 'deeplink',
      );
      // If no server specified but we're authenticated, just open chat
      final authState = ref.read(authNavigationStateProvider);
      if (authState == AuthNavigationState.authenticated) {
        await ref
            .read(appIntentCoordinatorProvider.notifier)
            .openChatFromExternal(
              prompt: prompt,
              focusComposer: true,
              resetChat: prompt != null && prompt.isNotEmpty,
            );
      }
      return;
    }

    DebugLogger.log(
      'Deep link: Chat with server: $serverUrl, prompt: $prompt',
      scope: 'deeplink',
    );

    // Check if we're already connected to this server
    final activeServer = await ref.read(activeServerProvider.future);
    final isConnectedToServer = activeServer != null &&
        _urlsMatch(activeServer.url, serverUrl);

    if (isConnectedToServer) {
      // Already connected - check auth state
      final authState = ref.read(authNavigationStateProvider);
      if (authState == AuthNavigationState.authenticated) {
        // Open chat with the prompt
        await ref
            .read(appIntentCoordinatorProvider.notifier)
            .openChatFromExternal(
              prompt: prompt,
              focusComposer: true,
              resetChat: prompt != null && prompt.isNotEmpty,
            );
        return;
      }
    }

    // Not connected to this server - navigate to server connection
    ref.read(pendingDeepLinkServerProvider.notifier).set(serverUrl);
    NavigationService.navigateToServerConnection();

    // TODO: Store prompt for after authentication completes
  }

  /// Check if two URLs match (ignoring trailing slashes and protocol differences).
  bool _urlsMatch(String url1, String url2) {
    String normalize(String url) {
      var normalized = url.toLowerCase().trim();
      // Remove trailing slash
      if (normalized.endsWith('/')) {
        normalized = normalized.substring(0, normalized.length - 1);
      }
      return normalized;
    }
    return normalize(url1) == normalize(url2);
  }
}
