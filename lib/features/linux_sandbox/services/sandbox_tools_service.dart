import 'dart:convert';

import '../models/linux_sandbox.dart';
import 'sandbox_runtime.dart';

class SandboxToolsService {
  const SandboxToolsService._();

  static bool isSandboxTool(String name) =>
      LinuxSandboxToolNames.all.contains(name);

  static bool toolNeedsApproval(LinuxSandbox sandbox, String toolName) {
    final cfg = sandbox.tools[toolName];
    if (cfg == null || !cfg.enabled) return false;
    return cfg.needsApproval;
  }

  static List<Map<String, dynamic>> buildToolDefinitions({
    required LinuxSandbox? sandbox,
    required bool supportsTools,
  }) {
    if (!supportsTools || sandbox == null) {
      return const <Map<String, dynamic>>[];
    }

    final tools = <Map<String, dynamic>>[];
    final cfg = sandbox.tools;

    if (cfg[LinuxSandboxToolNames.read]?.enabled == true) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LinuxSandboxToolNames.read,
          'description':
              'Read a text file or list a directory inside the Linux sandbox jail. '
              'Paths are relative to the sandbox root (forward slashes). '
              'Do not use absolute host paths.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description':
                    'Relative path inside the sandbox (e.g. "notes/todo.txt" or "." for root).',
              },
            },
            'required': ['path'],
          },
        },
      });
    }

    if (cfg[LinuxSandboxToolNames.write]?.enabled == true) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LinuxSandboxToolNames.write,
          'description':
              'Create or overwrite a text file inside the Linux sandbox jail. '
              'Parent directories are created as needed. Paths are relative to the sandbox root.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description': 'Relative path of the file to write.',
              },
              'content': {
                'type': 'string',
                'description': 'Full file contents to write.',
              },
            },
            'required': ['path', 'content'],
          },
        },
      });
    }

    if (cfg[LinuxSandboxToolNames.edit]?.enabled == true) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LinuxSandboxToolNames.edit,
          'description':
              'Replace the first occurrence of old_string with new_string in a '
              'file inside the Linux sandbox jail. Errors when old_string is not found.',
          'parameters': {
            'type': 'object',
            'properties': {
              'path': {
                'type': 'string',
                'description': 'Relative path of the file to edit.',
              },
              'old_string': {
                'type': 'string',
                'description': 'Exact text to replace (must be non-empty).',
              },
              'new_string': {
                'type': 'string',
                'description': 'Replacement text.',
              },
            },
            'required': ['path', 'old_string', 'new_string'],
          },
        },
      });
    }

    if (cfg[LinuxSandboxToolNames.shell]?.enabled == true) {
      tools.add(const {
        'type': 'function',
        'function': {
          'name': LinuxSandboxToolNames.shell,
          'description':
              'Run a shell command with the working directory set to the Linux '
              'sandbox root. Output is capped; long-running commands time out. '
              'Prefer read/write/edit for simple file operations.',
          'parameters': {
            'type': 'object',
            'properties': {
              'command': {
                'type': 'string',
                'description': 'Shell command to execute.',
              },
              'timeout_seconds': {
                'type': 'integer',
                'description':
                    'Optional timeout in seconds (default 30, max 120).',
              },
            },
            'required': ['command'],
          },
        },
      });
    }

    return tools;
  }

  static Future<String?> tryHandleToolCall({
    required String name,
    required Map<String, dynamic> args,
    required LinuxSandbox sandbox,
    required SandboxRuntime runtime,
  }) async {
    if (!isSandboxTool(name)) return null;

    final cfg = sandbox.tools[name];
    if (cfg == null || !cfg.enabled) {
      return jsonEncode({
        'ok': false,
        'error': 'tool_disabled',
        'message': 'Tool "$name" is disabled for this sandbox.',
      });
    }

    await runtime.ensureReady();
    SandboxToolResult result;

    switch (name) {
      case LinuxSandboxToolNames.read:
        final path = (args['path'] ?? '').toString();
        result = await runtime.read(path);
      case LinuxSandboxToolNames.write:
        final path = (args['path'] ?? '').toString();
        final content = (args['content'] ?? '').toString();
        result = await runtime.write(path, content);
      case LinuxSandboxToolNames.edit:
        final path = (args['path'] ?? '').toString();
        final oldString = (args['old_string'] ?? '').toString();
        final newString = (args['new_string'] ?? '').toString();
        result = await runtime.edit(path, oldString, newString);
      case LinuxSandboxToolNames.shell:
        final command = (args['command'] ?? '').toString();
        Duration? timeout;
        final rawTimeout = args['timeout_seconds'];
        if (rawTimeout is num) {
          timeout = Duration(seconds: rawTimeout.toInt());
        } else if (rawTimeout != null) {
          final parsed = int.tryParse(rawTimeout.toString());
          if (parsed != null) timeout = Duration(seconds: parsed);
        }
        result = await runtime.shell(command, timeout: timeout);
      default:
        return null;
    }

    return jsonEncode(result.toJson());
  }
}
