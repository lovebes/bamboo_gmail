defmodule Bamboo.GmailAdapter do
  @moduledoc """
  Documentation for Bamboo.GmailAdapter
  """

  import Bamboo.GmailAdapter.RFC2822, only: [render: 1]
  alias Bamboo.GmailAdapter.Errors.{ConfigError, TokenError, HTTPError}

  @gmail_auth_scope "https://www.googleapis.com/auth/gmail.send"
  @gmail_send_endpoint "https://www.googleapis.com/gmail/v1/users/me/messages/send"
  @behaviour Bamboo.Adapter

  def deliver(email, config) do
    handle_dispatch(email, config)
  end

  def handle_config(config) do
    validate_config_fields(config)
  end

  # TODO: Handle attachments
  def supports_attachments?, do: true

  defp handle_dispatch(email, config = %{sandbox: true}) do
    log_to_sandbox(config, label: "config")
    log_to_sandbox(email, label: "email")

    build_message(email)
    |> log_to_sandbox(label: "MIME message")
    |> Base.url_encode64()
    |> log_to_sandbox(label: "base64url encoded message")

    get_sub(config)
    |> get_access_token()
    |> log_to_sandbox(label: "access token")
  end

  defp handle_dispatch(email, config) do
    message =
      build_message(email)
      |> Base.url_encode64()

    get_sub(config)
    |> get_access_token()
    |> make_request(message)
  end

  defp build_message(email) do
    Mail.build_multipart()
    |> put_to(email)
    |> put_cc(email)
    |> put_bcc(email)
    |> put_from(email)
    |> put_subject(email)
    |> put_html_body(email)
    |> put_text_body(email)
    |> put_attachments(email)
    |> render()
  end

  defp put_to(message, %{to: recipients}) do
    recipients = Enum.map(recipients, fn {_, email} -> email end)
    Mail.put_to(message, recipients)
  end

  defp put_cc(message, %{cc: recipients}) do
    recipients = Enum.map(recipients, fn {_, email} -> email end)
    Mail.put_cc(message, recipients)
  end

  defp put_bcc(message, %{bcc: recipients}) do
    recipients = Enum.map(recipients, fn {_, email} -> email end)
    Mail.put_bcc(message, recipients)
  end

  defp put_from(message, %{from: {_, sender}}) do
    Mail.put_from(message, sender)
  end

  defp put_subject(message, %{subject: subject}) do
    Mail.put_subject(message, subject)
  end

  defp put_html_body(message, %{html_body: nil}), do: message

  defp put_html_body(message, %{html_body: html_body}) do
    Mail.put_html(message, html_body)
  end

  defp put_text_body(message, %{text_body: nil}), do: message

  defp put_text_body(message, %{text_body: text_body}) do
    Mail.put_text(message, text_body)
  end

  # TODO: Implement
  defp put_attachments(message, _attachment), do: message

  defp make_request(token, message) do
    headers = build_request_headers(token)
    body = build_request_body(message)

    case HTTPoison.post(@gmail_send_endpoint, body, headers) do
      {:ok, response} -> response
      {:error, error} -> handle_error(:http, error)
    end
  end

  # Right now `sub` is the only required field. 
  # TODO: Generalize this function
  defp validate_config_fields(config = %{sub: _}), do: config
  
  defp validate_config_fields(_no_match) do
    handle_error(:conf, "sub")
  end

  defp get_sub(%{sub: sub}) do
    case sub do
      {:system, s} -> validate_env_var(s)
      _ -> sub
    end
  end

  defp validate_env_var(env_var) do
    case var = System.get_env(env_var) do
      nil -> handle_error(:env, "Environment variable '#{env_var}' not found")
      _ -> var
    end
  end

  defp get_access_token(sub) do
    case Goth.Token.for_scope(@gmail_auth_scope, sub) do
      {:ok, token} -> Map.get(token, :token)
      {:error, error} -> handle_error(:auth, error)
    end
  end

  defp handle_error(scope, error) do
    case scope do
      :auth -> raise TokenError, message: error
      :http -> raise HTTPError, message: error
      :conf -> raise ConfigError, field: error
      :env -> raise ArgumentError, message: error
    end
  end

  defp build_request_headers(token) do
    [Authorization: "Bearer #{token}", "Content-Type": "application/json"]
  end

  defp build_request_body(message) do
    "{\"raw\": \"#{message}\"}"
  end

  defp log_to_sandbox(entity, label: label) do
    IO.puts("[sandbox] <#{label}> #{inspect(entity)}\n")
    entity
  end
end
