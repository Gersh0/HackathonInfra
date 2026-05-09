from datetime import datetime

from pydantic import BaseModel


class UserResponse(BaseModel):
    id: int
    display_name: str
    avatar_url: str | None
    created_at: datetime

    model_config = {"from_attributes": True}


class ProviderListResponse(BaseModel):
    providers: list[str]
