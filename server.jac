import:py from mtllm.llms {Ollama}
glob llm = Ollama(model_name='llama3.1');
import:jac from rag {RagEngine}
glob rag_engine:RagEngine = RagEngine();


enum ChatType {
    RAG : 'Need to use Retrievable information in specific documents to respond' = "RAG",
    QA : 'Given context is enough for an answer' = "user_qa"
}

node Router {
    can 'route the query to the appropriate task type'
    classify(message:'query from the user to be routed.':str) -> ChatType by llm(method="Reason", temperature=0.0);
}


walker interact {
    has message: str;
    has session_id: str;

    can init_session with `root entry {
         visit [-->](`?Session)(?id == self.session_id) else {
            session_node = here ++> Session(id=self.session_id, chat_history=[], status=1);
            print("Session Node Created");

            visit session_node;
        }
    }
}


node Session {
    has id: str;
    has chat_history: list[dict];
    has status: int = 1;

    can 'Respond to message using chat_history as context and agent_role as the goal of the agent'
    llm_chat(
        message:'current message':str,
        chat_history: 'chat history':list[dict],
        agent_role:'role of the agent responding':str,
        context:'retrieved context from documents':list
    ) -> 'response':str by llm();

    can chat with interact entry {
        self.chat_history.append({"role": "user", "content": here.message});
        response = infer(message=here.message, chat_history=self.chat_history) spawn root;
        self.chat_history.append({"role": "assistant", "content": response.response});

        report {
            "response": response.response
        };
    }
}


walker infer {
    has message:str;
    has chat_history: list[dict];

    can init_router with `root entry {
        visit [-->](`?Router) else {
            router_node = here ++> Router();
            router_node ++> RagChat();
            router_node ++> QAChat();
            visit router_node;
        }
    }

    can route with Router entry {
        classification = here.classify(message = self.message);
        visit [-->](`?Chat)(?chat_type==classification);
    }
}


walker analyze_response {
    has message: str;
    has response: str;
    has follow_up: str;

    can analyze_for_follow_up(message: str, response: str) -> str {
        if "more details" in response or "would you like" in response {
            return f"Do you need more details on {message}?";
        }
        elif "check again" in response {
            return "Would you like to ask for a recheck or clarification?";
        }
        elif "context" in response {
            return "Should I provide more context on the topic?";
        }
        else {
            return "";
        }
    }

    can suggest_follow_up with `root entry {
        follow_up = self.analyze_for_follow_up(message=self.message, response=self.response);
        
        if follow_up {
            here.follow_up = follow_up;
            report {
                "suggested_follow_up": follow_up
            };
        } 
        else {
            report {
                "suggested_follow_up": "No follow-up suggestion available."
            };
        }
    }
}


walker follow_up_check {
    has message: str;

    can check_follow_up with `root entry {
        follow_up_prompts = ["more details", "would you like", "need clarification", "can I assist further"];
        
        if self.message in follow_up_prompts {
            report {
                "follow_up_suggestion": "It seems you might need more information. Would you like to ask a follow-up question?"
            };
        } else {
            report {
                "follow_up_suggestion": "The response seems complete. Let me know if you have any further questions."
            };
        }
    }
}


node Chat {
    has chat_type: ChatType;
}


node RagChat :Chat: {
    has chat_type: ChatType = ChatType.RAG;

    can respond with infer entry {
        can 'Respond to message using chat_history as context and agent_role as the goal of the agent'
        respond_with_llm(   message:'current message':str,
                    chat_history: 'chat history':list[dict],
                    agent_role:'role of the agent responding':str,
                    context:'retirved context from documents':list
                        ) -> 'response':str by llm();
        data = rag_engine.get_from_chroma(query=here.message);
        here.response = respond_with_llm(here.message, here.chat_history, "You are a conversation agent designed to help users with their queries based on the documents provided", data);
    }
}

node QAChat :Chat: {
    has chat_type: ChatType = ChatType.QA;

    can respond with infer entry {
        can 'Respond to message using chat_history as context and agent_role as the goal of the agent'
        respond_with_llm(   message:'current message':str,
            chat_history: 'chat history':list[dict],
            agent_role:'role of the agent responding':str
                ) -> 'response':str by llm();
        here.response = respond_with_llm(here.message, here.chat_history, agent_role="You are a conversation agent designed to help users with their queries");
    }
}

