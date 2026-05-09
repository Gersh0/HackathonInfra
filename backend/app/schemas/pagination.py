from typing import Generic, TypeVar

from pydantic import BaseModel, model_validator


T = TypeVar("T")


class PaginatedResponse(BaseModel, Generic[T]):
    items: list[T]
    limit: int
    offset: int
    page_count: int
    total_count: int
    next_offset: int | None
    count: int | None = None

    @model_validator(mode="after")
    def set_count_alias(self) -> "PaginatedResponse[T]":
        if self.count is None:
            self.count = self.page_count
        return self
