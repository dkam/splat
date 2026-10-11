package com.example;

public class CheckoutError extends RuntimeException {
  public CheckoutError(String message, Throwable cause) {
    super(message, cause);
  }
}
