#include <iostream>
#include <string>
#include <utility>

#include "nlohmann/json.hpp"
#include "runtime/conversation/conversation.h"
#include "runtime/engine/engine_factory.h"
#include "runtime/engine/engine_settings.h"

int main(int argc, char** argv) {
  if (argc != 2) {
    std::cerr << "usage: litert_lm_x2_bridge MODEL_PATH\n";
    return 64;
  }

  auto assets = litert::lm::ModelAssets::Create(argv[1]);
  if (!assets.ok()) {
    std::cerr << "model_assets: " << assets.status() << "\n";
    return 2;
  }
  auto settings = litert::lm::EngineSettings::CreateDefault(
      std::move(*assets), litert::lm::Backend::CPU);
  if (!settings.ok()) {
    std::cerr << "engine_settings: " << settings.status() << "\n";
    return 3;
  }
  auto engine = litert::lm::EngineFactory::CreateDefault(std::move(*settings));
  if (!engine.ok()) {
    std::cerr << "engine: " << engine.status() << "\n";
    return 4;
  }
  auto config = litert::lm::ConversationConfig::CreateDefault(**engine);
  if (!config.ok()) {
    std::cerr << "conversation_config: " << config.status() << "\n";
    return 5;
  }
  auto conversation = litert::lm::Conversation::Create(**engine, *config);
  if (!conversation.ok()) {
    std::cerr << "conversation: " << conversation.status() << "\n";
    return 6;
  }

  auto response = (*conversation)->SendMessage({
      {"role", "user"}, {"content", "Reply with exactly: X2_OK"}});
  if (!response.ok()) {
    std::cerr << "generation: " << response.status() << "\n";
    return 7;
  }
  if (!response->contains("content") || !(*response)["content"].is_array()) {
    std::cerr << "generation: response has no content list\n";
    return 8;
  }
  std::string text;
  for (const auto& item : (*response)["content"]) {
    if (item.is_object() && item.contains("text") && item["text"].is_string()) {
      text += item["text"].get<std::string>();
    }
  }
  if (text.find("X2_OK") == std::string::npos) {
    std::cerr << "generation: content did not contain X2_OK\n";
    return 9;
  }
  // Keep internal channels such as reasoning_content out of the bridge contract.
  std::cout << nlohmann::json{{"content", text}}.dump() << "\n";
  return 0;
}
