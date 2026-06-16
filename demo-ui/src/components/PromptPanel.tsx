import { useEffect, useState } from "react";

interface Props {
  defaultPrompt: string;
}

export function PromptPanel({ defaultPrompt }: Props) {
  const [prompt, setPrompt] = useState(defaultPrompt);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState<string | null>(null);

  useEffect(() => {
    if (defaultPrompt) setPrompt(defaultPrompt);
  }, [defaultPrompt]);

  async function send() {
    setBusy(true);
    setResult(null);
    try {
      const res = await fetch("/api/prompt", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prompt }),
      });
      const data = await res.json();
      setResult(JSON.stringify(data, null, 2));
    } catch (e) {
      setResult(String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="prompt-panel">
      <label htmlFor="demo-prompt">Prompt confidential CVM</label>
      <div className="prompt-row">
        <input
          id="demo-prompt"
          value={prompt}
          onChange={(e) => setPrompt(e.target.value)}
          placeholder={defaultPrompt}
        />
        <button type="button" onClick={send} disabled={busy}>
          {busy ? "Sending…" : "Prompt CVM"}
        </button>
      </div>
      {result && <pre className="prompt-result">{result}</pre>}
    </div>
  );
}
