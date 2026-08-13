## Remove unused setup backend prompt

- Removed the unconnected `Commands::Setup::BackendPrompt` implementation and
  its self-contained tests. The setup command never required or constructed
  the prompt after it was introduced as a deferred setup slice.
- Removed stale comments that treated the prompt as a live collaborator;
  current setup-agent selection and installation behavior is unchanged.
