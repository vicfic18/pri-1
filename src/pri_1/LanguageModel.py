import json
from openai import OpenAI
from pydantic import BaseModel, Field
from pathlib import Path

class LanguageModel:
    def __init__(self):
        self.client = client = OpenAI(
            base_url="http://localhost:8080/v1",
            api_key="not-needed"  # Local server does not require an API key
        )
        self.system_prompt = (Path(__file__).parent / "prompt.txt").read_text()
        self.tools = tools = [
            {
                "type": "function",
                "function": {
                    "name": "get_current_weather",
                    "description": "Get the current weather for a given city.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "location": {
                                "type": "string",
                                "description": "The city and state, e.g. San Francisco, CA",
                            },
                            "unit": {
                                "type": "string",
                                "enum": ["celsius", "fahrenheit"],
                                "default": "celsius"
                            },
                        },
                        "required": ["location"],
                    },
                },
            }
        ]

    def single_ask(self, ask: str):
        response = self.client.chat.completions.create(
            model="local-model",  # llama-server accepts any string here
            messages=[
                {"role": "system", "content": self.system_prompt},
                {"role": "user", "content": ask},
            ],
            tools=self.tools,
            tool_choice="auto",
            temperature=0.1  # Lower temperature helps tool call reliability
        )
        
        message = response.choices[0].message

        # Process Output
        if message.tool_calls:
            for tool_call in message.tool_calls:
                fn_name = tool_call.function.name
                fn_args = json.loads(tool_call.function.arguments)
                
                print(f"Tool Requested: {fn_name}")
                print(f"Arguments: {fn_args}")
                
                return message.content
                # Dispatch function execution here in your assistant pipeline...
        else:
            print("Response:", message.content)
            return message.content

_default_model = LanguageModel()
single_ask = _default_model.single_ask