import '../exceptions/router_exceptions.dart';
import '../models/provider_capabilities.dart';
import '../models/provider_config.dart';
import 'openai_adapter.dart';

/// Streams chat completions from an Azure OpenAI deployment.
///
/// [ProviderConfig.baseUrl] is the deployment URL, such as
/// `https://my-resource.openai.azure.com/openai/deployments/my-gpt`, with an
/// optional `api-version` query parameter that defaults to [defaultApiVersion].
/// [ProviderConfig.azureOpenAi] builds it. The key is sent in the `api-key`
/// header and the cap as `max_completion_tokens`. The request and stream
/// shapes match [OpenAiAdapter].
class AzureOpenAiAdapter extends OpenAiAdapter {
  /// Creates an Azure OpenAI adapter.
  ///
  /// [client] is optional; see [OpenAiAdapter].
  AzureOpenAiAdapter({super.client});

  /// API version used when the deployment URL does not name one.
  static const defaultApiVersion = '2024-10-21';

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities.vision;

  @override
  Uri chatUrl(ProviderConfig config) {
    final baseUrl = config.baseUrl;
    if (baseUrl == null) {
      throw const TerminalLlmException(
        'Azure OpenAI needs the deployment URL as baseUrl; '
        'use ProviderConfig.azureOpenAi',
      );
    }
    final base = Uri.parse(baseUrl);
    final segments = <String>[
      ...base.pathSegments.where((segment) => segment.isNotEmpty),
      'chat',
      'completions',
    ];
    return base.replace(
      pathSegments: segments,
      queryParameters: <String, String>{
        'api-version': defaultApiVersion,
        ...base.queryParameters,
      },
    );
  }

  @override
  Map<String, String> authHeaders(ProviderConfig config) {
    return <String, String>{'api-key': config.apiKey};
  }

  @override
  String maxTokensField(Uri url) => 'max_completion_tokens';
}
