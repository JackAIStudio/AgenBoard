#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include <rime_api.h>

namespace {

std::vector<std::string> Candidates(RimeApi* rime, RimeSessionId session) {
  std::vector<std::string> result;
  RIME_STRUCT(RimeContext, context);
  if (!rime->get_context(session, &context)) {
    return result;
  }
  for (int index = 0; index < context.menu.num_candidates; ++index) {
    result.emplace_back(context.menu.candidates[index].text);
  }
  rime->free_context(&context);
  return result;
}

void PrintCandidates(RimeApi* rime,
                     RimeSessionId session,
                     const char* input) {
  rime->clear_composition(session);
  for (const char* cursor = input; *cursor; ++cursor) {
    rime->process_key(session, *cursor, 0);
  }

  const auto candidates = Candidates(rime, session);
  std::printf("%s", input);
  for (size_t index = 0; index < candidates.size(); ++index) {
    std::printf("\t%zu:%s", index + 1, candidates[index].c_str());
  }
  std::printf("\n");
}

bool HasExpectedFirstCandidate(RimeApi* rime,
                               RimeSessionId session,
                               const char* input,
                               const char* expected_candidate) {
  rime->clear_composition(session);
  for (const char* cursor = input; *cursor; ++cursor) {
    if (!rime->process_key(session, *cursor, 0)) {
      return false;
    }
  }
  const auto candidates = Candidates(rime, session);
  return !candidates.empty() && candidates.front() == expected_candidate;
}

bool LearnCandidate(RimeApi* rime,
                    RimeSessionId session,
                    const char* input,
                    const char* expected_candidate) {
  rime->clear_composition(session);
  for (const char* cursor = input; *cursor; ++cursor) {
    if (!rime->process_key(session, *cursor, 0)) {
      return false;
    }
  }

  const auto candidates = Candidates(rime, session);
  for (size_t index = 0; index < candidates.size(); ++index) {
    if (candidates[index] != expected_candidate) {
      continue;
    }
    if (!rime->select_candidate_on_current_page(session, index)) {
      return false;
    }

    RIME_STRUCT(RimeCommit, commit);
    if (rime->get_commit(session, &commit)) {
      rime->free_commit(&commit);
    } else if (rime->commit_composition(session) &&
               rime->get_commit(session, &commit)) {
      rime->free_commit(&commit);
    }
    return true;
  }
  return false;
}

}  // namespace

int main(int argc, char* argv[]) {
  if (argc != 4) {
    std::fprintf(stderr,
                 "usage: %s <shared-data-dir> <user-data-dir> "
                 "<prebuilt-data-dir>\n",
                 argv[0]);
    return 2;
  }

  RimeApi* rime = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.prebuilt_data_dir = argv[3];
  traits.app_name = "rime.agenboard-smoke-test";
  traits.distribution_name = "AgenBoard";
  traits.distribution_code_name = "agenboard";
  traits.distribution_version = "1";

  rime->setup(&traits);
  rime->initialize(&traits);

  const RimeSessionId session = rime->create_session();
  if (!session || !rime->select_schema(session, "agenboard_pinyin")) {
    std::fprintf(stderr, "failed to create Rime session or select schema\n");
    rime->finalize();
    return 1;
  }

  PrintCandidates(rime, session, "yingxiang");
  PrintCandidates(rime, session, "fengxian");
  PrintCandidates(rime, session, "zhongguo");
  PrintCandidates(rime, session, "shurufa");
  if (!HasExpectedFirstCandidate(rime, session, "yingxiang", "影响") ||
      !HasExpectedFirstCandidate(rime, session, "fengxian", "风险") ||
      !HasExpectedFirstCandidate(rime, session, "zhongguo", "中国") ||
      !HasExpectedFirstCandidate(rime, session, "shurufa", "输入法")) {
    std::fprintf(stderr, "unexpected first candidate\n");
    rime->destroy_session(session);
    rime->finalize();
    return 1;
  }

  for (int count = 0; count < 3; ++count) {
    if (!LearnCandidate(rime, session, "fengxian", "奉献")) {
      std::fprintf(stderr, "failed to exercise user dictionary learning\n");
      rime->destroy_session(session);
      rime->finalize();
      return 1;
    }
  }
  std::printf("after-learning\n");
  PrintCandidates(rime, session, "fengxian");
  if (!HasExpectedFirstCandidate(rime, session, "fengxian", "奉献")) {
    std::fprintf(stderr, "user dictionary did not change candidate order\n");
    rime->destroy_session(session);
    rime->finalize();
    return 1;
  }

  rime->destroy_session(session);
  rime->finalize();
  return 0;
}
