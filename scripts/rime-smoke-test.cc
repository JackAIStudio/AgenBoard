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

bool HasCandidateOnLaterPage(RimeApi* rime,
                             RimeSessionId session,
                             const char* input,
                             const char* expected_candidate) {
  rime->clear_composition(session);
  for (const char* cursor = input; *cursor; ++cursor) {
    if (!rime->process_key(session, *cursor, 0)) {
      return false;
    }
  }

  for (int page = 0; page < 32; ++page) {
    const auto candidates = Candidates(rime, session);
    for (const auto& candidate : candidates) {
      if (candidate == expected_candidate) {
        return page > 0;
      }
    }

    RIME_STRUCT(RimeContext, context);
    if (!rime->get_context(session, &context)) {
      return false;
    }
    const bool is_last_page = context.menu.is_last_page;
    rime->free_context(&context);
    if (is_last_page || !rime->change_page(session, false)) {
      return false;
    }
  }

  return false;
}

bool HasCandidateInSlice(RimeApi* rime,
                         RimeSessionId session,
                         const char* input,
                         int start_index,
                         int count,
                         const char* expected_candidate) {
  rime->clear_composition(session);
  for (const char* cursor = input; *cursor; ++cursor) {
    if (!rime->process_key(session, *cursor, 0)) {
      return false;
    }
  }

  RimeCandidateListIterator iterator = {0};
  if (!rime->candidate_list_from_index(session, &iterator, start_index)) {
    return false;
  }
  bool found = false;
  for (int index = 0; index < count && rime->candidate_list_next(&iterator);
       ++index) {
    if (std::strcmp(iterator.candidate.text, expected_candidate) == 0) {
      found = true;
      break;
    }
  }
  rime->candidate_list_end(&iterator);
  return found;
}

bool SupportsProgressiveCandidateSelection(RimeApi* rime,
                                           RimeSessionId session,
                                           const char* input,
                                           const char* partial_candidate,
                                           const char* expected_preedit,
                                           const char* final_candidate,
                                           const char* expected_commit) {
  rime->clear_composition(session);
  for (const char* cursor = input; *cursor; ++cursor) {
    if (!rime->process_key(session, *cursor, 0)) {
      return false;
    }
  }

  bool selected = false;
  for (int page = 0; page < 32 && !selected; ++page) {
    const auto candidates = Candidates(rime, session);
    for (size_t index = 0; index < candidates.size(); ++index) {
      if (candidates[index] == partial_candidate) {
        selected = rime->select_candidate_on_current_page(session, index);
        break;
      }
    }
    if (!selected && !rime->change_page(session, false)) {
      return false;
    }
  }
  if (!selected) {
    return false;
  }

  RIME_STRUCT(RimeCommit, commit);
  if (rime->get_commit(session, &commit)) {
    rime->free_commit(&commit);
    return false;
  }

  const char* raw_input = rime->get_input(session);
  RIME_STRUCT(RimeContext, context);
  if (!raw_input || !*raw_input ||
      !rime->get_context(session, &context)) {
    return false;
  }
  const std::string remaining_input = raw_input;
  const std::string preedit = context.composition.preedit
                                  ? context.composition.preedit
                                  : "";
  const std::string preview = context.commit_text_preview
                                  ? context.commit_text_preview
                                  : "";
  const bool has_remaining_candidates = context.menu.num_candidates > 0;
  std::printf("partial-selection\tinput:%s\tpreedit:%s\tpreview:%s\t"
              "selection:%d-%d\tcursor:%zu\n",
              remaining_input.c_str(),
              preedit.c_str(),
              preview.c_str(),
              context.composition.sel_start,
              context.composition.sel_end,
              rime->get_caret_pos(session));
  rime->free_context(&context);
  if (!has_remaining_candidates || remaining_input != input ||
      preedit != expected_preedit) {
    return false;
  }

  selected = false;
  for (int page = 0; page < 32 && !selected; ++page) {
    const auto candidates = Candidates(rime, session);
    for (size_t index = 0; index < candidates.size(); ++index) {
      if (candidates[index] == final_candidate) {
        selected = rime->select_candidate_on_current_page(session, index);
        break;
      }
    }
    if (!selected && !rime->change_page(session, false)) {
      return false;
    }
  }
  if (!selected) {
    return false;
  }

  RIME_STRUCT(RimeCommit, final_commit);
  if (!rime->get_commit(session, &final_commit)) {
    return false;
  }
  const std::string committed_text = final_commit.text ? final_commit.text : "";
  rime->free_commit(&final_commit);
  const char* completed_input = rime->get_input(session);
  std::printf("progressive-commit\ttext:%s\n", committed_text.c_str());
  return committed_text == expected_commit &&
      (!completed_input || !*completed_input);
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
  if (!HasCandidateOnLaterPage(rime, session, "yi", "熠") ||
      !HasCandidateInSlice(rime, session, "yi", 48, 48, "熠")) {
    std::fprintf(stderr,
                 "candidate paging did not expose 熠 after the first page\n");
    rime->destroy_session(session);
    rime->finalize();
    return 1;
  }
  if (!SupportsProgressiveCandidateSelection(
          rime, session, "yihui", "熠", "熠hui", "辉", "熠辉")) {
    std::fprintf(stderr,
                 "progressive candidate selection did not complete 熠辉\n");
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
