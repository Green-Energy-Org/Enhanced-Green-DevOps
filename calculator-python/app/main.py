from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Calculator Service")

class CalculationRequest(BaseModel):
    operation: str
    x: float
    y: float

@app.post("/calculate")
async def calculate(request: CalculationRequest):
    if request.operation == "add":
        result = request.x + request.y
    elif request.operation == "subtract":
        result = request.x - request.y
    else:
        result = "Operation not supported"
    
    return {"result": result}
