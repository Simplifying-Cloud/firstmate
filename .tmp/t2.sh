out=$(node 2>&1 <<'EOF'
case x in
  a) : ;;
esac
EOF
)
