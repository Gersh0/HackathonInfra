from datetime import datetime

from pydantic import BaseModel


class SubscriptionResponse(BaseModel):
    id: int
    follower_id: int
    creator_id: int
    created_at: datetime

    model_config = {"from_attributes": True}


class SubscriptionListResponse(BaseModel):
    creator_ids: list[int]
