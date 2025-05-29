## Project Structure

- **`/detecter/src/synthesis`**: Contains the modifications and extensions for multi-run monitoring:
    - **`lin_analyzer.erl`**: contains logic modified for operational rules implementation
    - **`history.erl`**: main module for history analysis

- **`/examples/erlang/props`**: Example formula mentioned in report:
    - **`prop_correct_start.hml`**: formula $\varphi_1$
    - **`prop_add_close.hml`**: formula $\varphi_3$
    - **`prop_add_req.hml`**: formula $\varphi_4$

- **`/examples/demo`**: Calculator server:
    - **`calc_server.erl`**: correct server implementation
    - **`calc_server_bug.erl`**: bugged server implementation

### Example Usage

1. Navigate to the examples directory from the root of the project and start the Erlang shell:
   ```bash
   cd examples/erlang
   erl -pa ../../detecter/ebin ebin
   ```
2. Compile the formula and weave the files:
    ```bash
    maxhml_eval:compile("props/prop_add_close.hml", [{outdir, "ebin"}]).
    lin_weaver:weave("src/demo", fun prop_add_close:mfa_spec/1, [{outdir, "ebin"}]).
    ```
3. Start the server:
    ```bash
    Pid = calc_server:start(0).
    ```