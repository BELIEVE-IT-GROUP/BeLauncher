// Production servicing layer for the LiteRT-LM local core: loads the model once, then serves
// OpenAI-compatible /v1/chat/completions requests over a local TCP socket for as long as the
// process runs. This is the direct successor to the X2 one-shot bridge (litert-lm-x2-bridge.cc,
// docs/spikes/litert-lm-x2.md): same proven Engine/Conversation calls, but the model load moves
// before the request loop instead of happening once per invocation, and the hardcoded "X2_OK"
// prompt is replaced by whatever the caller actually asked.
//
// The response shape matches IntelligenceClient.extractText's first branch (Sources/
// BeLauncherCore/Intelligence.swift) exactly, so BELHTTPModelProvider needs no changes to talk to
// this process: it is just another local provider entry in ModelProviderRegistry.
//
// Deliberately not a general HTTP server: one request at a time, blocking accept loop, no
// keep-alive, no chunked transfer. A local desktop app talking to its own subprocess on
// 127.0.0.1 does not need concurrency, and adding a threading/HTTP dependency here would be
// exactly the kind of speculative infrastructure this project's conventions warn against.

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstring>
#include <iostream>
#include <optional>
#include <string>
#include <utility>

#include "nlohmann/json.hpp"
#include "runtime/conversation/conversation.h"
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/engine_settings.h"
#include "schema/capabilities/speculative_decoding.h"

namespace {

struct HttpRequest {
  std::string method;
  std::string path;
  std::string body;
};

// Reads exactly one HTTP/1.1 request off `fd`: the request line (for method/path routing), enough
// of the headers to find Content-Length, then that many body bytes. Returns nullopt on a
// malformed or truncated request.
std::optional<HttpRequest> ReadRequest(int fd) {
  std::string buffer;
  char chunk[4096];
  size_t headerEnd = std::string::npos;
  while (headerEnd == std::string::npos) {
    ssize_t n = read(fd, chunk, sizeof(chunk));
    if (n <= 0) return std::nullopt;
    buffer.append(chunk, static_cast<size_t>(n));
    headerEnd = buffer.find("\r\n\r\n");
    if (buffer.size() > 1 << 20 && headerEnd == std::string::npos) return std::nullopt;
  }

  std::string headerBlock = buffer.substr(0, headerEnd);
  std::string requestLine = headerBlock.substr(0, headerBlock.find("\r\n"));
  std::string method, path;
  size_t methodEnd = requestLine.find(' ');
  size_t pathEnd = methodEnd == std::string::npos ? std::string::npos
                                                    : requestLine.find(' ', methodEnd + 1);
  if (methodEnd != std::string::npos && pathEnd != std::string::npos) {
    method = requestLine.substr(0, methodEnd);
    path = requestLine.substr(methodEnd + 1, pathEnd - methodEnd - 1);
  }

  size_t contentLength = 0;
  {
    std::string lower = headerBlock;
    for (auto& c : lower) c = static_cast<char>(::tolower(static_cast<unsigned char>(c)));
    auto pos = lower.find("content-length:");
    if (pos != std::string::npos) {
      contentLength = static_cast<size_t>(std::stoul(lower.substr(pos + 15)));
    }
  }

  std::string body = buffer.substr(headerEnd + 4);
  while (body.size() < contentLength) {
    ssize_t n = read(fd, chunk, sizeof(chunk));
    if (n <= 0) return std::nullopt;
    body.append(chunk, static_cast<size_t>(n));
  }
  body.resize(contentLength);
  return HttpRequest{std::move(method), std::move(path), std::move(body)};
}

// Derives a model id from the file name, matching the LM Studio shape BeLauncher already parses
// (`{"data":[{"id":"..."}]}`): "/path/to/gemma-4-E4B-it.litertlm" -> "gemma-4-E4B-it".
std::string ModelIdFromPath(const std::string& modelPath) {
  size_t slash = modelPath.find_last_of('/');
  std::string base = slash == std::string::npos ? modelPath : modelPath.substr(slash + 1);
  size_t dot = base.find_last_of('.');
  return dot == std::string::npos ? base : base.substr(0, dot);
}

void WriteResponse(int fd, int status, const std::string& statusText,
                    const nlohmann::json& payload) {
  std::string body = payload.dump();
  std::string response = "HTTP/1.1 " + std::to_string(status) + " " + statusText + "\r\n" +
                          "Content-Type: application/json\r\n" +
                          "Content-Length: " + std::to_string(body.size()) + "\r\n" +
                          "Connection: close\r\n\r\n" + body;
  size_t sent = 0;
  while (sent < response.size()) {
    ssize_t n = write(fd, response.data() + sent, response.size() - sent);
    if (n <= 0) return;
    sent += static_cast<size_t>(n);
  }
}

// Pulls the last user message out of an OpenAI-shaped {"messages": [...]} body. Only the prompt
// matters here: model name and sampling params are the caller's business, not this bridge's.
std::optional<std::string> ExtractPrompt(const nlohmann::json& request) {
  if (!request.contains("messages") || !request["messages"].is_array()) return std::nullopt;
  std::string prompt;
  for (const auto& message : request["messages"]) {
    if (message.value("role", "") == "user" && message.contains("content") &&
        message["content"].is_string()) {
      prompt = message["content"].get<std::string>();
    }
  }
  if (prompt.empty()) return std::nullopt;
  return prompt;
}

}  // namespace

int main(int argc, char** argv) {
  if (argc != 3) {
    std::cerr << "usage: litert_lm_server_bridge MODEL_PATH PORT\n";
    return 64;
  }
  const std::string modelPath = argv[1];
  const int port = std::stoi(argv[2]);
  const std::string modelId = ModelIdFromPath(modelPath);

  auto speculative =
      litert::lm::schema::capabilities::HasSpeculativeDecodingSupport(modelPath);
  if (!speculative.ok()) {
    std::cerr << "capability: " << speculative.status() << "\n";
    return 10;
  }

  // Everything below loads once, before the first request is accepted. This is the whole point
  // of the server over the X2 one-shot: the ~500ms-plus model load cost is paid at process start,
  // not per prompt.
  auto assets = litert::lm::ModelAssets::Create(modelPath);
  if (!assets.ok()) {
    std::cerr << "model_assets: " << assets.status() << "\n";
    return 2;
  }
  auto settings =
      litert::lm::EngineSettings::CreateDefault(std::move(*assets), litert::lm::Backend::CPU);
  if (!settings.ok()) {
    std::cerr << "engine_settings: " << settings.status() << "\n";
    return 3;
  }
  auto engine = litert::lm::EngineFactory::CreateDefault(std::move(*settings));
  if (!engine.ok()) {
    std::cerr << "engine: " << engine.status() << "\n";
    return 4;
  }

  int listenFd = socket(AF_INET, SOCK_STREAM, 0);
  if (listenFd < 0) {
    std::cerr << "socket: " << std::strerror(errno) << "\n";
    return 20;
  }
  int reuse = 1;
  setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

  sockaddr_in address{};
  address.sin_family = AF_INET;
  address.sin_addr.s_addr = inet_addr("127.0.0.1");  // Local core: never binds beyond loopback.
  address.sin_port = htons(static_cast<uint16_t>(port));
  if (bind(listenFd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) {
    std::cerr << "bind: " << std::strerror(errno) << "\n";
    return 21;
  }
  if (listen(listenFd, /*backlog=*/8) < 0) {
    std::cerr << "listen: " << std::strerror(errno) << "\n";
    return 22;
  }

  // One line on stdout, once, so the launching Swift process can confirm the socket is live
  // without polling the port immediately after spawning the child.
  std::cout << nlohmann::json{{"ready", true}, {"port", port},
                              {"speculative_decoding", *speculative}}
                   .dump()
            << std::endl;

  while (true) {
    int clientFd = accept(listenFd, nullptr, nullptr);
    if (clientFd < 0) continue;

    auto req = ReadRequest(clientFd);
    if (!req) {
      close(clientFd);
      continue;
    }

    // Matches Ollama's /api/tags and LM Studio's /v1/models: BeLauncher's local-provider discovery
    // (LocalModels.installed()) pings this before ever calling /v1/chat/completions, and treats a
    // provider with no models endpoint as never installed.
    if (req->method == "GET" && req->path == "/v1/models") {
      WriteResponse(clientFd, 200, "OK", {{"data", {{{"id", modelId}}}}});
      close(clientFd);
      continue;
    }

    nlohmann::json request;
    std::optional<std::string> prompt;
    try {
      request = nlohmann::json::parse(req->body);
      prompt = ExtractPrompt(request);
    } catch (const nlohmann::json::exception&) {
      prompt = std::nullopt;
    }

    // GET /healthz and any request this bridge cannot parse both land here: a 400 with no crash
    // is the whole health-check contract the Swift side needs.
    if (!prompt) {
      WriteResponse(clientFd, 400, "Bad Request", {{"error", "expected messages[].content"}});
      close(clientFd);
      continue;
    }

    auto config = litert::lm::ConversationConfig::CreateDefault(**engine);
    if (!config.ok()) {
      WriteResponse(clientFd, 500, "Internal Server Error",
                    {{"error", "conversation_config: " + config.status().ToString()}});
      close(clientFd);
      continue;
    }
    auto conversation = litert::lm::Conversation::Create(**engine, *config);
    if (!conversation.ok()) {
      WriteResponse(clientFd, 500, "Internal Server Error",
                    {{"error", "conversation: " + conversation.status().ToString()}});
      close(clientFd);
      continue;
    }

    auto response = (*conversation)->SendMessage({{"role", "user"}, {"content", *prompt}});
    if (!response.ok()) {
      WriteResponse(clientFd, 500, "Internal Server Error",
                    {{"error", "generation: " + response.status().ToString()}});
      close(clientFd);
      continue;
    }

    std::string text;
    if (response->contains("content") && (*response)["content"].is_array()) {
      for (const auto& item : (*response)["content"]) {
        if (item.is_object() && item.contains("text") && item["text"].is_string()) {
          text += item["text"].get<std::string>();
        }
      }
    }

    // choices[0].message.content: the exact shape IntelligenceClient.extractText reads first,
    // shared with Ollama and LM Studio responses (Sources/BeLauncherCore/Intelligence.swift).
    WriteResponse(clientFd, 200, "OK",
                 {{"choices", {{{"message", {{"role", "assistant"}, {"content", text}}}}}}});
    close(clientFd);
  }
}
