// lib/llm_chain.dart

import 'package:flutter/material.dart';
import 'package:langchain/langchain.dart';
import 'package:langchain_openai/langchain_openai.dart';
import 'package:langchain_google/langchain_google.dart';
import 'package:flutter_voice_friend/config.dart';
import 'package:flutter_voice_friend/llm_templates/summarizers/example_summarizer_user_template.dart';
import 'package:flutter_voice_friend/llm_templates/summarizers/example_summarizer_session.dart';

class LLMChainLibrary {
  // Toggle provider: false = OpenAI (default), true = Gemini.
  static const bool useGeminiModel = false;

  late ConversationBufferWindowMemory memory;
  late PromptTemplate promptTemplate;
  late PromptTemplate memoryUserSummaryTemplate;
  late PromptTemplate memorySessionSummaryTemplate;
  late PromptTemplate memoryAllSessionSummaryTemplate;
  late BaseChatModel llm;
  late ConversationChain llmChain;
  String template;

  // Constructor with optional parameters for dependency injection
  LLMChainLibrary(
    this.template, {
    ConversationBufferWindowMemory? memory,
    PromptTemplate? promptTemplate,
    PromptTemplate? memoryUserSummaryTemplate,
    PromptTemplate? memorySessionSummaryTemplate,
    PromptTemplate? memoryAllSessionSummaryTemplate,
    BaseChatModel? llm,
    ConversationChain? llmChain,
  }) {
    _initializeComponents(
      template,
      memory: memory,
      promptTemplate: promptTemplate,
      memoryUserSummaryTemplate: memoryUserSummaryTemplate,
      memorySessionSummaryTemplate: memorySessionSummaryTemplate,
      llm: llm,
      llmChain: llmChain,
    );
  }

  void _initializeComponents(
    String template, {
    ConversationBufferWindowMemory? memory,
    PromptTemplate? promptTemplate,
    PromptTemplate? memoryUserSummaryTemplate,
    PromptTemplate? memorySessionSummaryTemplate,
    BaseChatModel? llm,
    ConversationChain? llmChain,
  }) {
    this.memory = memory ??
        ConversationBufferWindowMemory(
          k: 15,
          memoryKey: "chat_history",
          aiPrefix: "AI",
          returnMessages: true,
        );
    this.promptTemplate =
        promptTemplate ?? PromptTemplate.fromTemplate(template);
    this.memoryUserSummaryTemplate = memoryUserSummaryTemplate ??
        PromptTemplate.fromTemplate(templateSummaryUser);
    this.memorySessionSummaryTemplate = memorySessionSummaryTemplate ??
        PromptTemplate.fromTemplate(templateSummarySession);
    this.llm = llm ?? _buildDefaultLlm();
    this.llmChain = llmChain ??
        ConversationChain(
          llm: this.llm,
          memory: this.memory,
          prompt: this.promptTemplate,
        );
  }

  BaseChatModel _buildDefaultLlm() {
    if (useGeminiModel) {
      return ChatGoogleGenerativeAI(
        apiKey: Config.googleApiKey,
        defaultOptions: const ChatGoogleGenerativeAIOptions(
          model: 'gemini-1.5-pro',
        ),
      );
    }

    return ChatOpenAI(
      apiKey: Config.openaiApiKey,
      defaultOptions: const ChatOpenAIOptions(model: 'gpt-4-turbo'),
    );
  }

  void setTemplate(String newTemplate) {
    template = newTemplate;
    _initializeComponents(newTemplate);
  }

  RunnableSequence<Object, String> getChain() {
    final chain = Runnable.fromMap({
      'language': Runnable.passthrough(),
      'input': Runnable.passthrough(),
      'user_information': Runnable.passthrough(),
      'session_history': Runnable.passthrough(),
      'chat_history': Runnable.mapInput(
        (_) async {
          final m = await memory.loadMemoryVariables();
          return m['chat_history'];
        },
      ),
    }).pipe(promptTemplate).pipe(llm).pipe(const StringOutputParser());

    return chain;
  }

  RunnableSequence<Object, String> getSummarizeUserChain() {
    debugPrint("Getting Summarize User Chain");

    final chain = Runnable.fromMap({
      'chat_history': Runnable.mapInput(
        (_) async {
          final m = await memory.loadMemoryVariables();
          return m['chat_history'];
        },
      ),
    })
        .pipe(memoryUserSummaryTemplate)
        .pipe(llm)
        .pipe(const StringOutputParser());

    return chain;
  }

  RunnableSequence<Object, String> getSummarizeSessionChain() {
    debugPrint("Getting Summarize Session Chain");

    final chain = Runnable.fromMap({
      'chat_history': Runnable.mapInput(
        (_) async {
          final m = await memory.loadMemoryVariables();
          return m['chat_history'];
        },
      ),
    })
        .pipe(memorySessionSummaryTemplate)
        .pipe(llm)
        .pipe(const StringOutputParser());
    return chain;
  }

  RunnableSequence<Object, String> getSummarizeAllSessionsChain() {
    debugPrint("Getting Summarize All Session Chain");

    final chain = Runnable.fromMap({
      'memory': Runnable.passthrough(),
      'conversations': Runnable.passthrough(),
    })
        .pipe(memoryAllSessionSummaryTemplate)
        .pipe(llm)
        .pipe(const StringOutputParser());

    return chain;
  }

  void updateMemory(input, output) {
    debugPrint("Updating chat Memory");
    memory.saveContext(
      inputValues: {'input': input},
      outputValues: {'output': output},
    );
  }

  void clearMemory() {
    debugPrint("Clearing chat Memory");
    memory.chatHistory.clear();
    memory.clear();
  }
}
