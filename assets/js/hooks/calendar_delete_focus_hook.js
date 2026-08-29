export const CalendarDeleteFocus = {
  mounted() {
    this.successRef = this.handleEvent("calendar_delete_focus", ({id}) => {
      if (typeof id === "string" && id === this.el.id) {
        this.el.focus({preventScroll: true})
      }
    })
  }
}

export default CalendarDeleteFocus
