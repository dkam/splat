package com.example;

public class CardNotFound extends RuntimeException {
  public CardNotFound(String message) {
    super(message);
  }
}
